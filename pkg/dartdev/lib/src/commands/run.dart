// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:dds/dds.dart';

import '../core.dart';
import '../sdk.dart';

class RunCommand extends DartdevCommand<int> {
  final ArgParser argParser = ArgParser.allowAnything();
  final bool verbose;
  RunCommand({this.verbose = false}) : super('run', '''
Run a Dart file.''');

  @override
  String get invocation => '${super.invocation} <dart file | package target>';

  @override
  void printUsage() {
    // Override [printUsage] for invocations of 'dart help run' which won't
    // execute [run] below.  Without this, the 'dart help run' reports the
    // command pub with no commands or flags.
    final command = sdk.dart;
    final args = [
      '--disable-dart-dev',
      '--help',
      if (verbose) '--verbose',
    ];

    log.trace('$command ${args.first}');

    // Call 'dart --help'
    // Process.runSync(..) is used since [printUsage] is not an async method,
    // and we want to guarantee that the result (the help text for the console)
    // is printed before command exits.
    final result = Process.runSync(command, args);
    if (result.stderr.isNotEmpty) {
      stderr.write(result.stderr);
    }
    if (result.stdout.isNotEmpty) {
      stdout.write(result.stdout);
    }
  }

  @override
  FutureOr<int> run() async {
    // the command line arguments after 'run'
    final args = argResults.arguments;

    // If the user wants to start a debugging session we need to do some extra
    // work and spawn a Dart Development Service (DDS) instance. DDS is a VM
    // service intermediary which implements the VM service protocol and
    // provides non-VM specific extensions (e.g., log caching, client
    // synchronization).
    if (args.any((element) => (element.startsWith('--observe') ||
        element.startsWith('--enable-vm-service')))) {
      return await _DebuggingSession(args).start();
    }

    // Starting in ProcessStartMode.inheritStdio mode means the child process
    // can detect support for ansi chars.
    final process = await Process.start(
        sdk.dart, ['--disable-dart-dev', ...args],
        mode: ProcessStartMode.inheritStdio);
    return process.exitCode;
  }
}

class _DebuggingSession {
  _DebuggingSession(List<String> args) : _args = args.toList() {
    // Process flags that are meant to configure the VM service HTTP server or
    // dump VM service connection information to a file. Since the VM service
    // clients won't actually be connecting directly to the service, we'll make
    // DDS appear as if it is the actual VM service.
    for (final arg in _args) {
      final isObserve = arg.startsWith('--observe');
      if (isObserve || arg.startsWith('--enable-vm-service')) {
        if (isObserve) {
          _observe = true;
        }
        // These flags can be provided by the embedder so we need to check for
        // both `=` and `:` separators.
        final observatoryBindInfo =
            (arg.contains('=') ? arg.split('=') : arg.split(':'))[1].split('/');
        _port = int.tryParse(observatoryBindInfo.first) ?? 0;
        if (observatoryBindInfo.length > 1) {
          try {
            _bindAddress = Uri.http(observatoryBindInfo[1], '');
          } on FormatException {
            // TODO(bkonyi): log invalid parse? The VM service just ignores bad
            // input flags.
            // Ignore.
          }
        }
      } else if (arg.startsWith('--write-service-info=')) {
        try {
          _serviceInfoUri = Uri.parse(arg.split('=')[1]);
        } on FormatException {
          // TODO(bkonyi): log invalid parse? The VM service just ignores bad
          // input flags.
          // Ignore.
        }
      }
    }

    // Strip --observe and --write-service-info from the arguments as we'll be
    // providing our own.
    _args.removeWhere(
      (arg) => (arg.startsWith('--observe') ||
          arg.startsWith('--enable-vm-service') ||
          arg.startsWith('--write-service-info')),
    );
  }

  FutureOr<int> start() async {
    // Output the service information for the target process to a temporary
    // file so we can avoid scraping stderr for the service URI.
    final serviceInfoDir =
        await Directory.systemTemp.createTemp('dart_service');
    final serviceInfoUri = serviceInfoDir.uri.resolve('service_info.json');
    final serviceInfoFile = await File.fromUri(serviceInfoUri).create();

    // Start using ProcessStartMode.normal and forward stdio manually as we
    // need to filter the true VM service URI and replace it with the DDS URI.
    _process = await Process.start(
      'dart',
      [
        '--disable-dart-dev',
        _observe
            ? '--observe=0'
            : '--enable-vm-service=0', // We don't care which port the VM service binds to.
        '--write-service-info=$serviceInfoUri',
        ..._args,
      ],
    );
    _forwardAndFilterStdio(_process);

    // Start DDS once the VM service has finished starting up.
    await Future.any([
      _waitForRemoteServiceUri(serviceInfoFile)
          .then((serviceUri) => _startDDS(serviceUri)),
      _process.exitCode,
    ]);

    return _process.exitCode.then((exitCode) async {
      // Shutdown DDS if it was started and wait for the process' stdio streams
      // to close so we don't truncate program output.
      await Future.wait([
        _dds?.shutdown(),
        _stderrDone,
        _stdoutDone,
      ]);
      return exitCode;
    });
  }

  Future<Uri> _waitForRemoteServiceUri(File serviceInfoFile) async {
    // Wait for VM service to write its connection info to disk.
    while ((await serviceInfoFile.length() <= 5)) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    final serviceInfoStr = await serviceInfoFile.readAsString();
    return Uri.parse(jsonDecode(serviceInfoStr)['uri']);
  }

  Future<void> _startDDS(Uri remoteVmServiceUri) async {
    _dds = await DartDevelopmentService.startDartDevelopmentService(
      remoteVmServiceUri,
      serviceUri: _bindAddress.replace(port: _port),
    );
    if (_serviceInfoUri != null) {
      // Output the service connection information.
      await File.fromUri(_serviceInfoUri).writeAsString(
        json.encode({
          'uri': _dds.uri.toString(),
        }),
      );
    }
    _ddsCompleter.complete();
  }

  void _forwardAndFilterStdio(Process process) {
    // Since VM service clients cannot connect to the real VM service once DDS
    // has started, replace all instances of the real VM service's URI with the
    // DDS URI. Clients should only know that they are connected to DDS if they
    // explicitly request that information via the protocol.
    String filterObservatoryUri(String msg) {
      if (_dds == null) {
        return msg;
      }
      if (msg.startsWith('Observatory listening on') ||
          msg.startsWith('Connect to Observatory at')) {
        // Search for the VM service URI in the message and replace it.
        msg = msg.replaceFirst(
          RegExp(r'https?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.'
              r'[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&//=]*)'),
          _dds.uri.toString(),
        );
      }
      return msg;
    }

    // Wait for DDS to start before handling any stdio events from the target
    // to ensure we don't let any unfiltered messages slip through.
    // TODO(bkonyi): consider filtering on bytes rather than decoding the UTF8.
    _stderrDone = process.stderr
        .transform(Utf8Decoder(allowMalformed: true))
        .listen((event) async {
      await _waitForDDS();
      stderr.write(filterObservatoryUri(event));
    }).asFuture();

    _stdoutDone = process.stdout
        .transform(Utf8Decoder(allowMalformed: true))
        .listen((event) async {
      await _waitForDDS();
      stdout.write(filterObservatoryUri(event));
    }).asFuture();

    stdin.listen(
      (event) async {
        await _waitForDDS();
        process.stdin.add(event);
      },
    );
  }

  Future<void> _waitForDDS() async {
    if (!_ddsCompleter.isCompleted) {
      // No need to wait for DDS if the process has already exited.
      await Future.any([
        _ddsCompleter.future,
        _process.exitCode,
      ]);
    }
  }

  Uri _bindAddress = Uri.http('127.0.0.1', '');
  DartDevelopmentService _dds;
  bool _observe = false;
  int _port;
  Process _process;
  Uri _serviceInfoUri;
  Future _stderrDone;
  Future _stdoutDone;

  final List<String> _args;
  final Completer<void> _ddsCompleter = Completer();
}
