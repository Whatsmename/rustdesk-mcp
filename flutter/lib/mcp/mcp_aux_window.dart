import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/terminal_connection_manager.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/terminal_model.dart';
import 'package:get/get.dart';

import 'mcp_utils.dart';

/// Most terminal lines one terminal_read returns.
const int kMcpTerminalMaxLines = 400;

// MCP calls the main window sends to a file transfer or terminal window.
//
// The main window decides which sessions an agent may touch (only the ones it
// opened) and resolves every local path inside the staging directory before
// calling. These handlers only act on the session named in the call. Every
// answer is a JSON string; a failure is `{"error": "..."}`, so the main window
// can report it as a tool error instead of a platform exception.

Map<String, dynamic> _state(FFI ffi) {
  final pi = ffi.ffiModel.pi;
  final ready = pi.isSet.value;
  final box = ffi.ffiModel.mcpLastMsgBox;
  final status = mcpConnectionState(
      ready: ready,
      msgType: box?['type'],
      msgTitle: box?['title'],
      msgText: box?['text']);
  return {
    'ready': ready,
    'state': status.state,
    if (status.message != null) 'message': status.message,
    if (ready) 'platform': pi.platform,
  };
}

Map<String, dynamic> _args(dynamic arguments) =>
    arguments is String ? jsonDecode(arguments) as Map<String, dynamic> : {};

Future<String> _guard(Future<Object?> Function() body) async {
  try {
    return jsonEncode(await body());
  } catch (e) {
    debugPrint('MCP window call failed: $e');
    return jsonEncode({'error': '$e'});
  }
}

// ---------------------------------------------------------------------------
// File transfer window
// ---------------------------------------------------------------------------

/// [peerIds] are the open file transfer tabs; [closeTab] closes one by peer id.
Future<dynamic> handleMcpFileWindowCall(String method, dynamic arguments,
    List<String> peerIds, void Function(String peerId) closeTab) async {
  final sessions = <String, FFI>{
    for (final id in peerIds)
      if (Get.isRegistered<FFI>(tag: 'ft_$id')) id: Get.find<FFI>(tag: 'ft_$id')
  };
  MapEntry<String, FFI> entryOf(Map<String, dynamic> a) {
    final e = sessions.entries
        .where((e) => e.value.sessionId.toString() == a['session_id'])
        .firstOrNull;
    if (e == null) throw 'Unknown session_id: ${a['session_id']}';
    return e;
  }

  switch (method) {
    case kWindowEventMcpAuxList:
      return jsonEncode([
        for (final e in sessions.entries)
          {
            'kind': 'file_transfer',
            'peer_id': e.key,
            'session_id': e.value.sessionId.toString(),
            ..._state(e.value),
            if (e.value.ffiModel.pi.isSet.value)
              'remote_home': e.value.fileModel.remoteController.homePath,
          }
      ]);
    case kWindowEventMcpAuxClose:
      return _guard(() async {
        closeTab(entryOf(_args(arguments)).key);
        return {'closed': true};
      });
    case kWindowEventMcpFtList:
      return _guard(() async {
        final a = _args(arguments);
        final ffi = entryOf(a).value;
        final remote = ffi.fileModel.remoteController;
        final isWindows = remote.options.value.isWindows;
        var path = a['path'] as String;
        // Same normalisation as FileController: /C:\ -> C:\ on Windows.
        if (isWindows && path.length > 1 && path[0] == '/') {
          path = path.substring(1);
          if (!path.endsWith('\\')) path = '$path\\';
        }
        final fd = await ffi.fileModel.fileFetcher
            .fetchDirectory(path, false, a['show_hidden'] == true);
        fd.format(isWindows);
        return {
          'path': fd.path,
          'is_windows': isWindows,
          'entries': [
            for (final e in fd.entries)
              {
                'name': e.name,
                'path': e.path,
                'type': e.isDrive
                    ? 'drive'
                    : e.isDirectory
                        ? 'dir'
                        : 'file',
                if (e.isFile) 'size': e.size,
                'modified': e.modifiedTime,
              }
          ],
        };
      });
    case kWindowEventMcpFtSend:
      return _guard(() async {
        final a = _args(arguments);
        final ffi = entryOf(a).value;
        final fm = ffi.fileModel;
        final upload = a['upload'] == true;
        final isDir = a['is_dir'] == true;
        final entry = Entry()
          ..name = a['name'] as String
          ..path = a['from'] as String
          ..entryType = isDir ? 1 : 4
          ..size = (a['size'] as int?) ?? 0;
        final jobId = fm.jobController.addTransferJob(entry, !upload);
        fm.mcpOverwrite[jobId] = a['overwrite'] == true;
        fm.jobController.registerTransferConflictBatch([jobId]);
        await bind.sessionSendFiles(
            sessionId: ffi.sessionId,
            actId: jobId,
            path: entry.path,
            to: a['to'] as String,
            fileNum: 0,
            includeHidden: a['include_hidden'] == true,
            isRemote: !upload,
            isDir: isDir);
        return {'job_id': jobId};
      });
    case kWindowEventMcpFtJobs:
      return _guard(() async {
        final a = _args(arguments);
        final fm = entryOf(a).value.fileModel;
        final ids = (a['job_ids'] as List).cast<int>().toSet();
        return {
          'jobs': [
            for (final j in fm.jobController.jobTable)
              if (ids.contains(j.id) && fm.mcpOverwrite.containsKey(j.id))
                {
                  'job_id': j.id,
                  'direction': j.isRemoteToLocal ? 'download' : 'upload',
                  'source': j.jobName,
                  'state': j.state.name,
                  if (j.fileName.isNotEmpty) 'current_file': j.fileName,
                  'files_done': j.recvJobRes ? j.fileNum + 1 : j.fileNum,
                  'file_count': j.fileCount,
                  'finished_bytes': j.finishedSize,
                  'total_bytes': j.totalSize,
                  'speed_bytes_per_s': j.speed.round(),
                  if (j.err.isNotEmpty) 'error': j.err,
                }
          ]
        };
      });
    case kWindowEventMcpFtCancel:
      return _guard(() async {
        final a = _args(arguments);
        final fm = entryOf(a).value.fileModel;
        final id = a['job_id'] as int;
        if (!fm.mcpOverwrite.containsKey(id)) {
          throw 'Job $id was not started by an MCP agent.';
        }
        await fm.jobController.cancelJob(id);
        return {'cancelled': id};
      });
  }
  return null;
}

// ---------------------------------------------------------------------------
// Terminal window
// ---------------------------------------------------------------------------

/// Tab keys are `<peerId>_<terminalId>`; one FFI (session) per peer serves
/// every terminal tab of that peer.
({String peerId, int terminalId})? _parseTabKey(String key) {
  final i = key.lastIndexOf('_');
  if (i <= 0) return null;
  final id = int.tryParse(key.substring(i + 1));
  return id == null ? null : (peerId: key.substring(0, i), terminalId: id);
}

String _readTerminal(TerminalModel model, int want) {
  final lines = model.terminal.lines;
  var end = lines.length;
  while (end > 0 && lines[end - 1].getText().trimRight().isEmpty) {
    end--;
  }
  // Count only logical lines: a soft-wrapped continuation joins its parent.
  var start = end;
  var logical = 0;
  while (start > 0 && logical < want) {
    start--;
    if (!lines[start].isWrapped) logical++;
  }
  final out = StringBuffer();
  for (var i = start; i < end; i++) {
    final line = lines[i];
    if (i > start && !line.isWrapped) out.write('\n');
    out.write(i + 1 < end && lines[i + 1].isWrapped
        ? line.getText()
        : line.getText().trimRight());
  }
  return out.toString();
}

/// [tabKeys] are the open terminal tabs; [closeTab] closes one by tab key.
Future<dynamic> handleMcpTerminalWindowCall(String method, dynamic arguments,
    List<String> tabKeys, void Function(String tabKey) closeTab) async {
  final tabs = <({String key, String peerId, int terminalId, FFI ffi})>[];
  for (final key in tabKeys) {
    final parsed = _parseTabKey(key);
    if (parsed == null) continue;
    final ffi = TerminalConnectionManager.getExistingConnection(parsed.peerId);
    if (ffi == null) continue;
    tabs.add((
      key: key,
      peerId: parsed.peerId,
      terminalId: parsed.terminalId,
      ffi: ffi
    ));
  }
  ({String key, String peerId, int terminalId, FFI ffi}) tabOf(
      Map<String, dynamic> a) {
    final mine = tabs
        .where((t) => t.ffi.sessionId.toString() == a['session_id'])
        .toList()
      ..sort((x, y) => x.terminalId.compareTo(y.terminalId));
    if (mine.isEmpty) throw 'Unknown session_id: ${a['session_id']}';
    final want = a['terminal_id'];
    if (want == null) return mine.first;
    final t = mine.where((t) => t.terminalId == want).firstOrNull;
    if (t == null) throw 'Unknown terminal_id $want for this session.';
    return t;
  }

  TerminalModel modelOf(
      ({String key, String peerId, int terminalId, FFI ffi}) t) {
    final model = t.ffi.terminalModels[t.terminalId];
    if (model == null) throw 'The terminal is still starting; try again.';
    return model;
  }

  switch (method) {
    case kWindowEventMcpAuxList:
      return jsonEncode([
        for (final t in tabs)
          {
            'kind': 'terminal',
            'peer_id': t.peerId,
            'session_id': t.ffi.sessionId.toString(),
            'terminal_id': t.terminalId,
            ..._state(t.ffi),
            'terminal_open':
                t.ffi.terminalModels[t.terminalId]?.terminalOpened ?? false,
          }
      ]);
    case kWindowEventMcpAuxClose:
      return _guard(() async {
        final a = _args(arguments);
        final sid = a['session_id'];
        final keys = [
          for (final t in tabs)
            if (t.ffi.sessionId.toString() == sid) t.key
        ];
        if (keys.isEmpty) throw 'Unknown session_id: $sid';
        keys.forEach(closeTab);
        return {'closed': keys.length};
      });
    case kWindowEventMcpTermRead:
      return _guard(() async {
        final a = _args(arguments);
        final t = tabOf(a);
        final model = modelOf(t);
        final want =
            ((a['lines'] as int?) ?? 60).clamp(1, kMcpTerminalMaxLines);
        return {
          'terminal_id': t.terminalId,
          'terminal_open': model.terminalOpened,
          if (model.mcpLastError != null) 'error': model.mcpLastError,
          'text': _readTerminal(model, want),
        };
      });
    case kWindowEventMcpTermWrite:
      return _guard(() async {
        final a = _args(arguments);
        final t = tabOf(a);
        final model = modelOf(t);
        final data = a['data'] as String;
        // Large inputs go in pieces so one message stays small.
        const chunk = 4096;
        var i = 0;
        while (i < data.length) {
          var end = math.min(i + chunk, data.length);
          // Never split a surrogate pair across two messages.
          if (end < data.length &&
              (data.codeUnitAt(end - 1) & 0xFC00) == 0xD800) {
            end--;
          }
          await model.mcpSend(data.substring(i, end));
          i = end;
        }
        return {'terminal_id': t.terminalId, 'sent': data.length};
      });
  }
  return null;
}
