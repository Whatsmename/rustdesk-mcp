import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/mcp/mcp_aux_backend.dart';
import 'package:flutter_hbb/mcp/mcp_backend.dart';
import 'package:flutter_hbb/mcp/mcp_dispatcher.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/mcp/mcp_aux_window.dart';
import 'package:uuid/uuid.dart';

const sid = '9a205f7e-f837-4f0c-ab91-b09822e801fc';

class Binding extends Fake implements RustdeskImpl {
  late Aux aux;
  int logins = 0;
  int codes = 0;
  @override
  String mainGetLocalOption({required String key, dynamic hint}) => 'Y';
  @override
  String sessionMcpConnectionId({required UuidValue sessionId, dynamic hint}) =>
      '';
  @override
  Future<String> mainGetHomeDir({dynamic hint}) async => '/unused';
  @override
  Future<void> sessionLogin(
      {required UuidValue sessionId,
      required String osUsername,
      required String osPassword,
      required String password,
      required bool remember,
      dynamic hint}) async {
    expect(sessionId.toString(), sid);
    expect(osUsername, isEmpty);
    expect(osPassword, isEmpty);
    expect(remember, false);
    expect(password, 'test-password');
    logins++;
    aux.state = 'ready';
  }

  @override
  Future<void> sessionSend2Fa(
      {required UuidValue sessionId,
      required String code,
      required bool trustThisDevice,
      dynamic hint}) async {
    expect(sessionId.toString(), sid);
    expect(code, 'test-code');
    expect(trustThisDevice, false);
    codes++;
    aux.state = 'ready';
  }
}

class Aux extends McpAuxSessions {
  Aux({required super.approve, required super.stopped});
  String? kind;
  String state = 'needs_password';
  int resets = 0;
  bool rejectReset = false;
  void Function()? onReset;
  @override
  List<int> windowIds(String kind) => [1];
  @override
  Future<void> openWindow(String kind, String peerId, bool elevated) async {
    this.kind = kind;
  }

  @override
  Future<String> stagingDir() async => '/test-staging';
  @override
  Future<dynamic> invokeWindow(int windowId, String method, Object? args,
      [Duration timeout = const Duration(seconds: 3)]) async {
    if (method == kWindowEventMcpAuxList) {
      return jsonEncode(kind == null
          ? []
          : [
              {
                'kind': kind,
                'peer_id': '101763146',
                'session_id': sid,
                'state': state,
                'ready': state == 'ready',
              }
            ]);
    }
    if (method == kWindowEventMcpAuthenticate) {
      expect(args, {'session_id': sid}); // No password/code on window IPC.
      resets++;
      onReset?.call();
      if (rejectReset) return false;
      state = 'connecting';
      return true;
    }
    throw StateError('Unexpected window call $method');
  }
}

class Backend extends RustDeskMcpBackend {
  Backend(this.aux)
      : super(
            approveConnect: (_) async => false,
            approveAux: (_, __) async => false);
  final Aux aux;
  @override
  McpAuxSessions get auxiliarySessions => aux;
}

class PromptModel extends Fake implements FfiModel {
  @override
  final pi = PeerInfo();
  @override
  Map<String, String>? mcpLastMsgBox;
}

class PromptSession extends Fake implements FFI {
  @override
  final ffiModel = PromptModel();
  @override
  final dialogManager = OverlayDialogManager();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Binding binding;
  late Aux aux;
  late Backend backend;
  var approvals = 0;
  var stopped = false;
  setUp(() {
    approvals = 0;
    stopped = false;
    aux = Aux(
        approve: (_, __) async {
          approvals++;
          return true;
        },
        stopped: () => stopped);
    binding = Binding()..aux = aux;
    platformFFI.setBindingForTesting(binding);
    backend = Backend(aux);
  });

  for (final kind in ['terminal', 'file_transfer']) {
    test('approved $kind authenticates its exact auxiliary ID', () async {
      final opened = kind == 'terminal'
          ? await backend.openTerminal('101763146')
          : await backend.openFileTransfer('101763146');
      expect(opened['state'], 'needs_password');
      expect(approvals, 1);
      final result = await backend.authenticate(sid, password: 'test-password');
      expect(result['state'], 'ready');
      expect(binding.logins, 1);
      expect(aux.resets, 1);
    });
  }

  test(
      'owned auxiliary control request explains approval instead of desktop lookup',
      () async {
    await backend.openTerminal('101763146');
    await expectLater(
        backend.requestControl(sid),
        throwsA(isA<McpToolException>().having((e) => e.message, 'message',
            contains('already locally approved'))));
  });

  test('owned auxiliary 2FA does not trust the device', () async {
    await backend.openTerminal('101763146');
    aux.state = 'needs_2fa';
    final result = await backend.authenticate(sid, twoFactorCode: 'test-code');
    expect(result['state'], 'ready');
    expect(binding.codes, 1);
    expect(binding.logins, 0);
  });

  test('administrator account boundary is never submitted by authenticate',
      () async {
    await backend.openTerminal('101763146');
    aux.state = 'needs_admin_login';
    await expectLater(
        backend.authenticate(sid, password: 'test-password'),
        throwsA(isA<McpToolException>().having((e) => e.message, 'message',
            contains('Administrator credentials'))));
    expect(binding.logins, 0);
    expect(aux.resets, 0);
  });

  test('shutdown while window answers cancels credential submission', () async {
    await backend.openTerminal('101763146');
    aux.onReset = () {
      stopped = true;
    };
    await expectLater(backend.authenticate(sid, password: 'test-password'),
        throwsA(isA<McpToolException>()));
    expect(binding.logins, 0);
  });

  test('window declining a stale prompt cancels credential submission',
      () async {
    await backend.openTerminal('101763146');
    aux.rejectReset = true;
    await expectLater(backend.authenticate(sid, password: 'test-password'),
        throwsA(isA<McpToolException>()));
    expect(binding.logins, 0);
  });

  test('missing password does not clear the prompt', () async {
    await backend.openTerminal('101763146');
    await expectLater(
        backend.authenticate(sid), throwsA(isA<McpToolException>()));
    expect(aux.resets, 0);
    expect(binding.logins, 0);
  });

  test('denied local approval never owns or authenticates the session',
      () async {
    final denied = Aux(approve: (_, __) async => false, stopped: () => false);
    await expectLater(
        denied.open('terminal', '101763146'), throwsA(isA<McpToolException>()));
    final b = Backend(denied);
    await expectLater(b.authenticate(sid, password: 'test-password'),
        throwsA(isA<McpToolException>()));
    expect(denied.owns(sid), false);
    expect(binding.logins, 0);
  });

  for (final type in ['input-password', 're-input-password', 'input-2fa']) {
    test('window prepares only normal credential prompt $type', () {
      final ffi = PromptSession();
      ffi.ffiModel.mcpLastMsgBox = {'type': type};
      expect(prepareMcpAuxAuthentication(ffi), true);
      expect(ffi.ffiModel.mcpLastMsgBox, isNull);
    });
  }
  for (final type in [
    'terminal-admin-login',
    'terminal-admin-login-password',
    'terminal-admin-login-request-approval'
  ]) {
    test('window retains administrator dialog $type', () {
      final ffi = PromptSession();
      ffi.ffiModel.mcpLastMsgBox = {'type': type};
      expect(prepareMcpAuxAuthentication(ffi), false);
      expect(ffi.ffiModel.mcpLastMsgBox?['type'], type);
    });
  }

  for (final kind in ['terminal', 'file_transfer']) {
    test('unowned $kind session cannot authenticate', () async {
      aux.kind = kind; // Human-opened, never locally approved.
      await expectLater(backend.authenticate(sid, password: 'test-password'),
          throwsA(isA<McpToolException>()));
      expect(binding.logins, 0);
      expect(aux.resets, 0);
    });
  }
}
