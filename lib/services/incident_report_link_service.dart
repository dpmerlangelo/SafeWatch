import 'package:flutter/foundation.dart';

enum LinkTarget { incident, report }

class LinkRequest {
  final LinkTarget target;
  final String id; // incident id or report id
  LinkRequest(this.target, this.id);
}

/// Lets IncidentsScreen and IncidentReportScreen open each other's records.
///
/// Flow: a screen calls [openIncident] / [openReport]. The desktop shell
/// listens and switches tabs. The TARGET screen listens too, waits until its
/// data has loaded, opens the record, then calls [consume].
class IncidentReportLinkService {
  IncidentReportLinkService._();
  static final instance = IncidentReportLinkService._();

  final ValueNotifier<LinkRequest?> pending = ValueNotifier(null);

  void openIncident(String incidentId) =>
      pending.value = LinkRequest(LinkTarget.incident, incidentId);

  void openReport(String reportId) =>
      pending.value = LinkRequest(LinkTarget.report, reportId);

  void consume() => pending.value = null;
}