import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import '../logging.dart';
import '../package.dart';
import 'git_commit.dart';
import 'git_repository.dart';
import 'io.dart';
import 'pending_package_update.dart';
import 'versioning.dart';

class Changelog {
  Changelog(this.package, this.version, this.logger);

  final Package package;
  final Version version;
  final MelosLogger logger;

  String get markdown {
    throw UnimplementedError();
  }

  String get path {
    return p.join(package.path, 'CHANGELOG.md');
  }

  @override
  String toString() {
    return markdown;
  }

  Future<String> read() async {
    if (fileExists(path)) {
      return readTextFile(path);
    }
    return '';
  }

  Future<void> write() async {
    var contents = await read();
    if (contents.contains(markdown)) {
      logger.trace(
        'Identical changelog content for ${package.name} v$version already '
        'exists, skipping.',
      );
      return;
    }
    contents = '$markdown$contents';

    await writeTextFileAsync(path, contents);
  }
}

class MelosChangelog extends Changelog {
  MelosChangelog(this.update, MelosLogger logger)
    : super(update.package, update.nextVersion, logger);

  final MelosPendingPackageUpdate update;

  @override
  String get markdown {
    return (StringBuffer()..writePackageChangelog(update)).toString();
  }
}

extension MarkdownStringBufferExtension on StringBuffer {
  void writeBold(String string) {
    write('**');
    write(string);
    write('**');
  }

  void writePunctuated(String string) {
    write(string);

    final shouldPunctuate = !string.contains(RegExp(r'[\.\?\!]$'));
    if (shouldPunctuate) {
      write('.');
    }
  }

  void writeLink(String name, {String? uri}) {
    write('[');
    write(name);
    write(']');
    if (uri != null) {
      write('(');
      write(uri);
      write(')');
    }
  }
}

extension ChangelogStringBufferExtension on StringBuffer {
  void writePackageChangelog(MelosPendingPackageUpdate update) {
    final config = update.workspace.config;
    final includeDate = config.commands.version.includeDateInChangelogEntry;

    // Changelog entry header.
    write('## ');
    if (includeDate) {
      final now = DateTime.now();

      write(update.nextVersion);
      write(' - ');
      writeln(now.toFormattedString());
    } else {
      writeln(update.nextVersion);
    }
    writeln();

    if (update.reason == PackageUpdateReason.dependency) {
      // Dependency change entry.
      writeln(' - Update a dependency to the latest release.');
      writeln();
    }

    if (update.reason == PackageUpdateReason.graduate) {
      // Package graduation entry.
      writeln(
        ' - Graduate package to a stable release. See pre-releases prior to '
        'this version for changelog entries.',
      );
      writeln();
    }

    if (update.reason == PackageUpdateReason.commit ||
        update.reason == PackageUpdateReason.manual) {
      // Breaking change note.
      if (update.hasBreakingChanges) {
        writeln('> Note: This release has breaking changes.');
        writeln();
      }

      writePackageUpdateChanges(update);
    }
  }

  void writePackageUpdateChanges(MelosPendingPackageUpdate update) {
    final config = update.workspace.config;
    final repository = config.repository;
    final linkToCommits = config.commands.version.linkToCommits;
    final includeCommitId = config.commands.version.includeCommitId;

    String processCommitHeader(String header) =>
        repository != null ? header.withIssueLinks(repository) : header;

    // User provided changelog entry message.
    if (update.userChangelogMessage != null) {
      writeln(' - ${update.userChangelogMessage}');
      writeln();
    }

    // Entries for commits included in new version.
    final commits = _filteredAndSortedCommits(update);
    if (commits.isNotEmpty) {
      for (final commit in commits) {
        final parsedMessage = commit.parsedMessage;

        write(' - ');

        if (parsedMessage.isBreakingChange) {
          writeBold('BREAKING');
          write(' ');
        }

        writeBold(parsedMessage.type!.toUpperCase());
        if (config.commands.version.includeScopes) {
          if (parsedMessage.scopes.isNotEmpty) {
            write('(');
            write(parsedMessage.scopes.join(','));
            write(')');
          }
        }
        write(': ');
        writePunctuated(processCommitHeader(parsedMessage.description!));

        if (linkToCommits || includeCommitId) {
          final shortCommitId = commit.id.substring(0, 8);
          final commitUrl = repository!.commitUrl(commit.id);
          write(' (');
          if (linkToCommits) {
            writeLink(shortCommitId, uri: commitUrl.toString());
          } else {
            write(shortCommitId);
          }
          write(')');
        }

        writeln();

        final version = update.workspace.config.commands.version;

        if (!version.includeCommitBody) {
          continue;
        }
        if (parsedMessage.body == null) {
          continue;
        }

        final shouldWriteBody =
            !version.commitBodyOnlyBreaking || parsedMessage.isBreakingChange;

        if (shouldWriteBody) {
          writeln();
          for (final line in parsedMessage.body!.split('\n')) {
            write(' ' * 4);
            writeln(line);
          }
          writeln();
        }
      }
      writeln();
    }
  }
}

List<RichGitCommit> _filteredAndSortedCommits(
  MelosPendingPackageUpdate update,
) {
  final commits = update.commits
      .where((commit) => commit.parsedMessage.isVersionableCommit)
      .toList();

  // Sort so that Breaking Changes appear at the top.
  commits.sort((a, b) {
    final r = a.parsedMessage.isBreakingChange.toString().compareTo(
      b.parsedMessage.isBreakingChange.toString(),
    );
    if (r != 0) {
      return r;
    }
    return b.parsedMessage.type!.compareTo(a.parsedMessage.type!);
  });

  return commits;
}

// https://regex101.com/r/Q1IV9n/1
final _issueLinkRegexp = RegExp(r'#(\d+)');

extension on String {
  String withIssueLinks(HostedGitRepository repository) {
    return replaceAllMapped(_issueLinkRegexp, (match) {
      final issueUrl = repository.issueUrl(match.group(1)!);
      return '[${match.group(0)}]($issueUrl)';
    });
  }
}

extension DateTimeExtension on DateTime {
  /// Returns a formatted string in the format `yyyy-MM-dd`.
  @internal
  String toFormattedString() {
    return toIso8601String().substring(0, 10);
  }
}
