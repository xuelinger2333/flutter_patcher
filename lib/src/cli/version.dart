/// The package version; test/cli/version_test.dart keeps it equal to pubspec.yaml.
const packageVersion = '1.0.0+1';

/// The plugin version hosts compare patches against: [packageVersion]
/// without its build suffix, since hosts read only major.minor.patch.
String get pluginVersion => packageVersion.split('+').first;
