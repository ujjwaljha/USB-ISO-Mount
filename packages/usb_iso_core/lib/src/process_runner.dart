import 'dart:convert';
import 'dart:io';

class CommandResult {
  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get success => exitCode == 0;
}

/// Runs host commands, widening PATH on macOS so Homebrew tools resolve.
class ProcessRunner {
  ProcessRunner({this.environment});

  final Map<String, String>? environment;

  Map<String, String> get _env {
    final merged = Map<String, String>.from(Platform.environment);
    if (Platform.isMacOS) {
      final path = merged['PATH'] ?? '';
      merged['PATH'] = '/opt/homebrew/bin:/usr/local/bin:$path';
    }
    if (Platform.isLinux) {
      final path = merged['PATH'] ?? '';
      merged['PATH'] = '/usr/sbin:/sbin:/usr/local/bin:$path';
    }
    if (environment != null) {
      merged.addAll(environment!);
    }
    return merged;
  }

  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    bool elevated = false,
  }) async {
    if (elevated && Platform.isMacOS) {
      return _runMacElevated(executable, arguments);
    }

    final exe = elevated && Platform.isLinux ? 'sudo' : executable;
    final args = elevated && Platform.isLinux
        ? [executable, ...arguments]
        : arguments;

    try {
      final result = await Process.run(
        exe,
        args,
        workingDirectory: workingDirectory,
        environment: _env,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      return CommandResult(
        exitCode: result.exitCode,
        stdout: result.stdout as String,
        stderr: result.stderr as String,
      );
    } on ProcessException catch (error) {
      return CommandResult(exitCode: 127, stdout: '', stderr: error.message);
    }
  }

  Future<Process> start(
    String executable,
    List<String> arguments, {
    bool elevated = false,
  }) {
    if (elevated && Platform.isMacOS) {
      final command = [executable, ...arguments].map(_shellQuote).join(' ');
      final escaped = _appleScriptEscape(command);
      final script = 'do shell script "$escaped" with administrator privileges';
      return Process.start('osascript', ['-e', script], environment: _env);
    }
    if (elevated && Platform.isLinux) {
      return Process.start('sudo', [
        executable,
        ...arguments,
      ], environment: _env);
    }
    return Process.start(executable, arguments, environment: _env);
  }

  Future<CommandResult> _runMacElevated(
    String executable,
    List<String> arguments,
  ) async {
    final command = [executable, ...arguments].map(_shellQuote).join(' ');
    final escaped = _appleScriptEscape(command);
    final script = 'do shell script "$escaped" with administrator privileges';
    final result = await Process.run(
      'osascript',
      ['-e', script],
      environment: _env,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    return CommandResult(
      exitCode: result.exitCode,
      stdout: result.stdout as String,
      stderr: result.stderr as String,
    );
  }

  static String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\\''")}'";
  }

  static String _appleScriptEscape(String value) {
    return value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  }
}
