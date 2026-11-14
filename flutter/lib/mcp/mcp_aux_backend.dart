import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/file_model.dart' show PathUtil;
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/download_paths.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:path/path.dart' as p;

import 'mcp_dispatcher.dart';
import 'mcp_utils.dart';

const Duration _kWindowCallTimeout = Duration(seconds: 3);
const Duration _kListTimeout = Duration(seconds: 15);
const Duration _kOpenTimeout = Duration(seconds: 20);
// Longest one tool call blocks; matches the remote desktop tools.
const Duration _kCallBudget = Duration(seconds: 25);
const int _kMaxWaitMs = 20000;

/// States in which a newly opened session waits for someone else.
const _kSettledStates = {
  'ready',
  'needs_password',
  'wrong_password',
  'needs_2fa',
  'needs_admin_login',
  'waiting_for_remote_accept',
  'error',
};

typedef McpAuxApproval = Future<bool?> Function(String peerId, String what);

class _AuxSession {
  final String kind; // file_transfer | terminal
  final String peerId;
  final bool elevated;
  final Set<int> jobs = {};
  _AuxSession(this.kind, this.peerId, {this.elevated = false});
}

/// File transfer and terminal sessions opened by MCP agents.
///
/// An agent can only act on sessions it opened here; sessions the user opened
/// are never listed or touched. Each kind is off until the user enables it,
/// and every session is approved by the user when it opens.
class McpAuxSessions {
  final McpAuxApproval approve;
  final bool Function() stopped;
  McpAuxSessions({required this.approve, required this.stopped});

  final Map<String, _AuxSession> _owned = {};
  final Map<String, int> _windowOf = {};
  final _opening = McpSingleFlight<String>();

  bool owns(String sessionId) => _owned.containsKey(sessionId);

  // --- window plumbing -----------------------------------------------------

  List<int> _windows(String kind) => kind == 'terminal'
      ? rustDeskWinManager.terminalWindows
      : rustDeskWinManager.fileTransferWindows;

  Future<dynamic> _invoke(int windowId, String method, Object? args,
      [Duration timeout = _kWindowCallTimeout]) async {
    try {
      return await DesktopMultiWindow.invokeMethod(
              windowId, method, args == null ? null : jsonEncode(args))
          .timeout(timeout);
    } on TimeoutException {
      throw McpToolException('The RustDesk window did not respond. If it was '
          'just opened, try again in a moment.');
    }
  }

  /// Every file transfer or terminal session in the open windows, the user's
  /// included. Internal: tools only ever see the ones in [_owned].
  Future<List<Map<String, dynamic>>> _all(String kind) async =>
      (await _scan(kind)).sessions;

  /// [complete] is false when some window did not answer (it may be busy or
  /// still starting): a session missing from such a scan is not gone.
  Future<({List<Map<String, dynamic>> sessions, bool complete})> _scan(
      String kind) async {
    final out = <Map<String, dynamic>>[];
    var complete = true;
    for (final w in _windows(kind)) {
      try {
        final raw = await _invoke(w, kWindowEventMcpAuxList, null);
        if (raw is! String) {
          complete = false;
          continue;
        }
        for (final s
            in (jsonDecode(raw) as List).cast<Map<String, dynamic>>()) {
          _windowOf[s['session_id'] as String] = w;
          out.add(s);
        }
      } catch (_) {
        complete = false;
      }
    }
    return (sessions: out, complete: complete);
  }

  Map<String, dynamic> _describe(Map<String, dynamic> s) {
    final own = _owned[s['session_id']]!;
    final hint = s['ready'] == true ? null : mcpNextStep(s['state'] as String);
    return {
      ...s,
      if (own.kind == 'terminal') 'elevated': own.elevated,
      if (hint != null) 'next_step': hint,
    };
  }

  Future<List<Map<String, dynamic>>> list() async {
    final out = <Map<String, dynamic>>[];
    for (final kind in const ['file_transfer', 'terminal']) {
      final scan = await _scan(kind);
      final seen = <String>{};
      for (final s in scan.sessions) {
        final sid = s['session_id'] as String;
        // A peer's terminal tabs share one session; report it once.
        if (owns(sid) && _owned[sid]!.kind == kind && seen.add(sid)) {
          out.add(_describe(s));
        }
      }
      // Forget closed sessions, but only on a scan every window answered.
      if (scan.complete) {
        _owned
            .removeWhere((sid, own) => own.kind == kind && !seen.contains(sid));
      }
    }
    return out;
  }

  Future<({_AuxSession own, Map<String, dynamic> state, int window})> _session(
      String sessionId,
      {String? kind}) async {
    final own = _owned[sessionId];
    if (own == null || (kind != null && own.kind != kind)) {
      throw McpToolException(kind == null
          ? 'Unknown session_id: $sessionId'
          : 'Unknown ${kind.replaceAll('_', ' ')} session_id: $sessionId. '
              'Open one with ${kind == 'terminal' ? 'open_terminal' : 'open_file_transfer'}.');
    }
    final scan = await _scan(own.kind);
    final s =
        scan.sessions.where((s) => s['session_id'] == sessionId).firstOrNull;
    if (s == null) {
      if (!scan.complete) {
        throw McpToolException('The RustDesk window did not respond. Try '
            'again in a moment.');
      }
      _owned.remove(sessionId);
      throw McpToolException('The session $sessionId has been closed.');
    }
    return (own: own, state: s, window: _windowOf[sessionId]!);
  }

  Future<({_AuxSession own, Map<String, dynamic> state, int window})> _ready(
      String sessionId, String kind) async {
    final s = await _session(sessionId, kind: kind);
    if (s.state['ready'] != true) {
      final d = _describe(s.state);
      throw McpToolException('The session is not ready (${d['state']}). '
          '${d['next_step'] ?? mcpNotReadyMessage}');
    }
    return s;
  }

  Future<Map<String, dynamic>> _call(
      int window, String method, Map<String, dynamic> args,
      [Duration timeout = _kWindowCallTimeout]) async {
    final raw = await _invoke(window, method, args, timeout);
    if (raw is! String) {
      throw McpToolException('The RustDesk window could not handle $method.');
    }
    final answer = jsonDecode(raw) as Map<String, dynamic>;
    final error = answer['error'];
    if (error != null) throw McpToolException('$error');
    return answer;
  }

  // --- opening -------------------------------------------------------------

  Future<Map<String, dynamic>> open(String kind, String peerId,
      {bool elevated = false}) async {
    peerId = peerId.replaceAll(' ', '');
    final option = kind == 'terminal'
        ? kOptionMcpAllowTerminal
        : kOptionMcpAllowFileTransfer;
    if (!mainGetLocalBoolOptionSync(option)) {
      throw McpToolException('MCP ${kind == 'terminal' ? 'terminal' : 'file '
              'transfer'} access is turned off. Only the user can turn it on, in '
          'Settings > General > MCP server.');
    }
    if (elevated) {
      final peer =
          gFFI.recentPeersModel.peers.where((x) => x.id == peerId).firstOrNull;
      if (peer == null || peer.platform != kPeerPlatformWindows) {
        throw McpToolException('An administrator terminal is only available '
            'for Windows peers that this client has connected to before.');
      }
    }
    final deadline = DateTime.now().add(_kCallBudget);
    final key = '$kind:$peerId';
    var opening = _opening.pending(key);
    if (opening == null) {
      for (final s in await _all(kind)) {
        if (s['peer_id'] != peerId) continue;
        final sid = s['session_id'] as String;
        final own = _owned[sid];
        if (own == null) {
          throw McpToolException('The user has a '
              '${kind == 'terminal' ? 'terminal' : 'file transfer'} session '
              'open to $peerId. Ask them to close it, or to work in it '
              'themselves.');
        }
        if (own.elevated != elevated) {
          throw McpToolException(
              'A ${own.elevated ? 'administrator' : 'normal'} '
              'terminal to $peerId is already open (session $sid). Close it '
              'with disconnect first.');
        }
        return _describe(s);
      }
      opening = _opening.start(key, () => _open(kind, peerId, elevated));
    }
    final String sessionId;
    try {
      sessionId = await opening.timeout(deadline.difference(DateTime.now()));
    } on TimeoutException {
      return {
        'kind': kind,
        'peer_id': peerId,
        'ready': false,
        'state': 'opening',
        'next_step': 'The user has not answered the request yet, or the '
            'window is still opening. Call the same open tool again to keep '
            'waiting.',
      };
    }
    return _settle(sessionId, deadline);
  }

  Future<String> _open(String kind, String peerId, bool elevated) async {
    if (stopped()) throw McpToolException('The MCP server has stopped.');
    final what = kind == 'file_transfer'
        ? 'a file transfer session (files move only through the '
            '~/$kMcpStagingDirName folder on this computer)'
        : elevated
            ? 'an ADMINISTRATOR terminal session (the peer will ask you for '
                'Windows administrator credentials in its window)'
            : 'a terminal session (a command shell on the remote computer)';
    final allowed = await approve(peerId, what);
    if (allowed == null) {
      throw McpToolException('The request for $peerId timed out without an '
          'answer from the user.');
    }
    if (!allowed) throw McpToolException('The user denied the request.');
    if (stopped()) throw McpToolException('The MCP server has stopped.');
    // The user may have opened one while the prompt was up; that stays theirs.
    // A busy window could hide it, and the new session would then be mistaken
    // for theirs, so only a complete scan lets the open go ahead.
    final before = await _scan(kind);
    if (!before.complete) {
      throw McpToolException('A RustDesk window did not respond. Call the '
          'open tool again in a moment.');
    }
    if (before.sessions.any((s) => s['peer_id'] == peerId)) {
      throw McpToolException('The user opened a session to $peerId meanwhile.');
    }
    if (kind == 'terminal') {
      // Read and cleared by the new session (session_add_sync).
      if (elevated) setEnvTerminalAdmin();
      await rustDeskWinManager.newTerminal(peerId);
    } else {
      await rustDeskWinManager.newFileTransfer(peerId);
    }
    final until = DateTime.now().add(_kOpenTimeout);
    while (DateTime.now().isBefore(until)) {
      for (final s in await _all(kind)) {
        if (s['peer_id'] == peerId) {
          final sid = s['session_id'] as String;
          _owned[sid] = _AuxSession(kind, peerId, elevated: elevated);
          return sid;
        }
      }
      await Future.delayed(const Duration(milliseconds: 250));
    }
    throw McpToolException('Timed out waiting for the window to open.');
  }

  Future<Map<String, dynamic>> _settle(
      String sessionId, DateTime deadline) async {
    while (true) {
      final s = await _session(sessionId);
      if (_kSettledStates.contains(s.state['state']) ||
          !DateTime.now().isBefore(deadline)) {
        final d = _describe(s.state);
        if (d['kind'] == 'file_transfer') d['staging_dir'] = await stagingDir();
        return d;
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  Future<Map<String, dynamic>> get(String sessionId, {int waitMs = 0}) {
    final deadline = DateTime.now()
        .add(Duration(milliseconds: waitMs.clamp(0, _kMaxWaitMs)));
    return _settle(sessionId, deadline);
  }

  Future<void> close(String sessionId) async {
    final s = await _session(sessionId);
    await _call(s.window, kWindowEventMcpAuxClose, {'session_id': sessionId});
    _owned.remove(sessionId);
  }

  // --- staging directory (local side of every transfer) --------------------

  /// `~/RustDesk-MCP`, created on first use; its real path.
  Future<String> stagingDir() async {
    final dir =
        Directory(p.join(await bind.mainGetHomeDir(), kMcpStagingDirName));
    await dir.create(recursive: true);
    return dir.resolveSymbolicLinksSync();
  }

  /// [relative] resolved inside the staging directory. Absolute paths, `..`
  /// escapes and symbolic links (anywhere on the way) are refused.
  Future<String> _local(String relative, {bool mustExist = true}) async {
    final root = await stagingDir();
    final rel = relative.trim();
    if (p.isAbsolute(rel) || rel.startsWith('~')) {
      throw McpToolException('Local paths are relative to the staging folder '
          '$root; absolute paths are not allowed.');
    }
    final joined = p.normalize(p.join(root, rel.isEmpty ? '.' : rel));
    if (joined != root && !p.isWithin(root, joined)) {
      throw McpToolException('Local path "$relative" is outside the staging '
          'folder.');
    }
    if (!mustExist) return joined;
    final type = FileSystemEntity.typeSync(joined, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw McpToolException('Local path "$relative" does not exist in the '
          'staging folder.');
    }
    if (type == FileSystemEntityType.link) {
      throw McpToolException('Local path "$relative" is a symbolic link; '
          'links are not transferred.');
    }
    // A linked directory higher up would point outside the folder.
    final real = File(joined).resolveSymbolicLinksSync();
    if (real != root && !p.isWithin(root, real)) {
      throw McpToolException('Local path "$relative" resolves outside the '
          'staging folder.');
    }
    return joined;
  }

  // --- file transfer -------------------------------------------------------

  Future<Map<String, dynamic>> listFiles(String sessionId,
      {required String side, String? path, bool showHidden = false}) async {
    final s = await _ready(sessionId, 'file_transfer');
    if (side == 'local') {
      final root = await stagingDir();
      final dir = await _local(path ?? '');
      if (FileSystemEntity.typeSync(dir, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw McpToolException('"${path ?? ''}" is not a directory.');
      }
      final entries = <Map<String, dynamic>>[];
      for (final e in Directory(dir).listSync(followLinks: false)) {
        final name = p.basename(e.path);
        if (!showHidden && name.startsWith('.')) continue;
        final stat = e.statSync();
        entries.add({
          'name': name,
          'path': p.relative(e.path, from: root),
          'type': e is Link
              ? 'link'
              : e is Directory
                  ? 'dir'
                  : 'file',
          if (e is File) 'size': stat.size,
          'modified': stat.modified.millisecondsSinceEpoch ~/ 1000,
        });
      }
      entries.sort((a, b) => (a['name'] as String).compareTo(b['name']));
      return {
        'side': 'local',
        'staging_dir': root,
        'path': p.relative(dir, from: root),
        'entries': entries,
      };
    }
    if (side != 'remote') {
      throw McpToolException('`side` must be `remote` or `local`.');
    }
    final remotePath = (path == null || path.isEmpty)
        ? (s.state['remote_home'] as String? ?? '')
        : path;
    final listing = await _call(
        s.window,
        kWindowEventMcpFtList,
        {
          'session_id': sessionId,
          'path': remotePath,
          'show_hidden': showHidden,
        },
        _kListTimeout);
    return {'side': 'remote', ...listing};
  }

  Future<Map<String, dynamic>> transferFile(String sessionId,
      {required String direction,
      required String path,
      String? remoteDir,
      String? localName,
      bool overwrite = false,
      bool includeHidden = false}) async {
    final s = await _ready(sessionId, 'file_transfer');
    final remoteWindows = s.state['platform'] == kPeerPlatformWindows;
    final Map<String, dynamic> send;
    if (direction == 'download') {
      // Find the entry in its parent listing: that gives its type and size.
      final parent = PathUtil.dirname(path, remoteWindows);
      final name = PathUtil.split(path, remoteWindows).lastOrNull ?? '';
      final listing = await _call(
          s.window,
          kWindowEventMcpFtList,
          {'session_id': sessionId, 'path': parent, 'show_hidden': true},
          _kListTimeout);
      final entry = (listing['entries'] as List)
          .cast<Map<String, dynamic>>()
          .where((e) => e['name'] == name)
          .firstOrNull;
      if (entry == null || entry['type'] == 'drive') {
        throw McpToolException('Remote path "$path" was not found. Use '
            'list_files with side `remote` to get exact paths.');
      }
      final target = (localName ?? name).trim();
      if (!DownloadPaths.validName(target, windows: Platform.isWindows)) {
        throw McpToolException('"$target" is not a valid local file name.');
      }
      final to = await _local(target, mustExist: false);
      if (!overwrite &&
          FileSystemEntity.typeSync(to, followLinks: false) !=
              FileSystemEntityType.notFound &&
          entry['type'] == 'file') {
        throw McpToolException('"$target" already exists in the staging '
            'folder. Pass overwrite: true to replace it, or local_name.');
      }
      send = {
        'from': entry['path'],
        'to': to,
        'name': name,
        'is_dir': entry['type'] == 'dir',
        'size': entry['size'] ?? 0,
        'upload': false,
      };
    } else if (direction == 'upload') {
      if (remoteDir == null || remoteDir.isEmpty) {
        throw McpToolException('`remote_dir` (an existing remote folder) is '
            'required for an upload.');
      }
      final from = await _local(path);
      final isDir = FileSystemEntity.typeSync(from, followLinks: false) ==
          FileSystemEntityType.directory;
      if (isDir) {
        // Nothing reachable through a link may leave the computer.
        final link = Directory(from)
            .listSync(recursive: true, followLinks: false)
            .whereType<Link>()
            .firstOrNull;
        if (link != null) {
          throw McpToolException('"$path" contains a symbolic link '
              '(${p.relative(link.path, from: await stagingDir())}); '
              'remove it before uploading.');
        }
      }
      final name = (localName ?? p.basename(from)).trim();
      if (!DownloadPaths.validName(name, windows: remoteWindows)) {
        throw McpToolException('"$name" is not a valid file name on the '
            'peer.');
      }
      send = {
        'from': from,
        'to': PathUtil.join(remoteDir, name, remoteWindows),
        'name': p.basename(from),
        'is_dir': isDir,
        'size': isDir ? 0 : File(from).lengthSync(),
        'upload': true,
      };
    } else {
      throw McpToolException('`direction` must be `download` or `upload`.');
    }
    final started = await _call(s.window, kWindowEventMcpFtSend, {
      'session_id': sessionId,
      ...send,
      'overwrite': overwrite,
      'include_hidden': includeHidden,
    });
    final jobId = started['job_id'] as int;
    s.own.jobs.add(jobId);
    return {
      'job_id': jobId,
      'direction': direction,
      'from': send['upload'] == true ? path : send['from'],
      'to': send['upload'] == true
          ? send['to']
          : p.relative(send['to'] as String, from: await stagingDir()),
      'next_step': 'Call transfer_status with this job_id (and wait_ms) to '
          'follow it.',
    };
  }

  Future<Map<String, dynamic>> transferStatus(String sessionId,
      {int? jobId, int waitMs = 0}) async {
    final s = await _session(sessionId, kind: 'file_transfer');
    if (jobId != null && !s.own.jobs.contains(jobId)) {
      throw McpToolException('Unknown job_id $jobId for this session.');
    }
    final ids = jobId == null ? s.own.jobs.toList() : [jobId];
    final deadline = DateTime.now()
        .add(Duration(milliseconds: waitMs.clamp(0, _kMaxWaitMs)));
    while (true) {
      final jobs = (await _call(s.window, kWindowEventMcpFtJobs,
          {'session_id': sessionId, 'job_ids': ids}))['jobs'] as List;
      final running =
          jobs.any((j) => j['state'] == 'inProgress' || j['state'] == 'none');
      if (!running || !DateTime.now().isBefore(deadline)) {
        return {'jobs': jobs};
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<Map<String, dynamic>> cancelTransfer(
      String sessionId, int jobId) async {
    final s = await _session(sessionId, kind: 'file_transfer');
    if (!s.own.jobs.contains(jobId)) {
      throw McpToolException('Unknown job_id $jobId for this session.');
    }
    return _call(s.window, kWindowEventMcpFtCancel,
        {'session_id': sessionId, 'job_id': jobId});
  }

  // --- terminal ------------------------------------------------------------

  Future<Map<String, dynamic>> terminalRead(String sessionId,
      {int lines = 60, int? terminalId}) async {
    final s = await _ready(sessionId, 'terminal');
    return _call(s.window, kWindowEventMcpTermRead, {
      'session_id': sessionId,
      'lines': lines,
      if (terminalId != null) 'terminal_id': terminalId,
    });
  }

  Future<Map<String, dynamic>> terminalWrite(String sessionId, String text,
      {bool submit = false,
      int waitMs = 0,
      int lines = 60,
      int? terminalId}) async {
    final s = await _ready(sessionId, 'terminal');
    // A terminal's Enter key is CR; line breaks in the text submit each line.
    var data = text.replaceAll(RegExp(r'\r\n|\n'), '\r');
    if (submit) data += '\r';
    final sent = await _call(s.window, kWindowEventMcpTermWrite, {
      'session_id': sessionId,
      'data': data,
      if (terminalId != null) 'terminal_id': terminalId,
    });
    if (waitMs <= 0) return sent;
    // Return once output has been quiet for a moment, or at the deadline.
    final deadline = DateTime.now()
        .add(Duration(milliseconds: waitMs.clamp(0, _kMaxWaitMs)));
    String? last;
    var quiet = 0;
    Map<String, dynamic> read = const {};
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 300));
      read =
          await terminalRead(sessionId, lines: lines, terminalId: terminalId);
      if (read['text'] == last) {
        if (++quiet >= 3) break;
      } else {
        quiet = 0;
        last = read['text'] as String?;
      }
    }
    return {...sent, ...read};
  }
}
