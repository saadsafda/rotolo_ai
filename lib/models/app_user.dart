import 'report.dart';

enum AppRole { owner, admin, staff }

class AppUser {
  const AppUser({
    required this.id,
    required this.displayName,
    required this.email,
    required this.role,
    required this.canSubmitPayments,
    required this.canReviewPayments,
    required this.readableSources,
  });

  final String id;
  final String displayName;
  final String email;
  final AppRole role;
  final bool canSubmitPayments;
  final bool canReviewPayments;

  /// Mirrors `section_access` (server RLS is authoritative; this only drives UI).
  final Set<SectionSource> readableSources;

  bool canRead(SectionSource s) => readableSources.contains(s);
  bool get isOwnerOrAdmin => role == AppRole.owner || role == AppRole.admin;
  bool get canRefresh => isOwnerOrAdmin;
  bool get canSeePayments => canSubmitPayments || canReviewPayments;

  String get firstName => displayName.split(' ').first;
  String get initials =>
      displayName.split(' ').where((w) => w.isNotEmpty).take(2).map((w) => w[0].toUpperCase()).join();

  /// "Harry R."
  String get shortName {
    final parts = displayName.split(' ').where((w) => w.isNotEmpty).toList();
    return parts.length < 2 ? displayName : '${parts.first} ${parts.last[0]}.';
  }

  String get roleLabel => switch (role) {
        AppRole.owner => 'Owner',
        AppRole.admin => 'Admin',
        AppRole.staff => 'Staff',
      };
}

/// Defaults from the migration, pending decision D2.
Set<SectionSource> defaultSourcesFor(AppRole role) => switch (role) {
      AppRole.owner || AppRole.admin => SectionSource.values.toSet(),
      AppRole.staff => {SectionSource.fubDeals},
    };
