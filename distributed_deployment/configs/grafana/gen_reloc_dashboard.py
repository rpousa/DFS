#!/usr/bin/env python3
"""Generates configs/grafana/dashboards/reloc-control.json (CU-UP relocation control)."""
import json
import sys

CTL = {"type": "frser-sqlite-datasource", "uid": "relocctl"}
KPM = {"type": "frser-sqlite-datasource", "uid": "edthsvykzynswc"}
CTL_URL = "http://172.31.54.33:8085"

ARGS = ("var-ue=${ue}&var-sst=${sst}&var-target=${target}&var-metric=${metric}&var-cmp=${cmp}"
        "&var-threshold=${threshold}&var-consecutive=${consecutive}&var-guard=${guard}"
        "&var-guard_cmp=${guard_cmp}&var-guard_threshold=${guard_threshold}")

pid = [0]


def q(sql, ds=CTL, ref="A", kind="table", time_cols=("time",)):
    return {"refId": ref, "datasource": ds, "queryType": kind, "rawQueryText": sql, "queryText": sql,
            "timeColumns": list(time_cols)}


def panel(title, ptype, x, y, w, h, targets, ds=CTL, **extra):
    pid[0] += 1
    p = {"id": pid[0], "title": title, "type": ptype, "datasource": ds,
         "gridPos": {"x": x, "y": y, "w": w, "h": h}, "targets": targets}
    p.update(extra)
    return p


STATE_MAP = [{"type": "value", "options": {
    "armed": {"text": "ARMED · watching", "color": "blue", "index": 0},
    "fired": {"text": "FIRED · CONTROL sent", "color": "orange", "index": 1},
    "acked": {"text": "ACKED · relocating", "color": "orange", "index": 2},
    "complete": {"text": "COMPLETE", "color": "green", "index": 3},
    "switched": {"text": "SWITCHED (KPM)", "color": "green", "index": 4},
    "timeout": {"text": "TIMEOUT · never fired", "color": "red", "index": 5},
    "failed": {"text": "FAILED", "color": "red", "index": 6},
    "given up": {"text": "GIVEN UP by CU-CP", "color": "red", "index": 7},
    "stopped": {"text": "STOPPED", "color": "text", "index": 8},
}}]

SLICE_CASE = ("CASE {c} WHEN 1 THEN 'eMBB' WHEN 2 THEN 'URLLC' WHEN 3 THEN 'mIoT' WHEN 4 THEN 'V2X' "
              "WHEN 5 THEN 'HMTC' WHEN 0 THEN 'no slice label' ELSE 'SST ' || {c} END")


def text_stat(title, x, y, w, h, sql, field, mappings=None, color_mode="background", unit=None, desc=""):
    return panel(title, "stat", x, y, w, h, [q(sql)], description=desc,
                 options={"reduceOptions": {"values": False, "calcs": ["lastNotNull"], "fields": f"/^{field}$/"},
                          "colorMode": color_mode, "graphMode": "none", "textMode": "value", "justifyMode": "center",
                          "text": {"valueSize": 26}},
                 fieldConfig={"defaults": {"mappings": mappings or [], "unit": unit or "string",
                                           "color": {"mode": "fixed", "fixedColor": "text"} if not mappings else
                                           {"mode": "thresholds"},
                                           "thresholds": {"mode": "absolute", "steps": [{"color": "text", "value": None}]}},
                              "overrides": []})


panels = []

help_md = f"""**Choose** UE, slice, target CU-UP and the rule in the bar above, then press a button.
Every press first stops any trigger already running, so only one instance ever runs.

### [▶ Arm trigger](${{ctl}}/arm?{ARGS}) &nbsp; [⚡ Relocate now](${{ctl}}/now?{ARGS}) &nbsp; [■ Stop](${{ctl}}/stop?{ARGS})

* **Arm trigger**: fires when *metric* stays {{above/below}} *threshold* for *N* reports in a row on the chosen slice (any slice when "any"), optionally only while the guard holds.
* **Relocate now**: moves the UE to the target on the next DU report.
* Units: DRB.UEThpDl kbit/s · DRB.PdcpSduDelayDl 0.1 ms · DRB.RlcSduDelayDl µs · DRB.RlcBufOccDl bytes.

The same three actions are in the dashboard links at the top right."""

panels.append(panel("Control", "text", 0, 0, 9, 9, [], ds=None,
                    options={"mode": "markdown", "content": help_md}))
panels.append(text_stat("Relocation status", 9, 0, 5, 4,
                        "SELECT state FROM runs ORDER BY id DESC LIMIT 1", "state", STATE_MAP,
                        desc="State of the newest run: armed -> fired -> acked -> complete (CU-CP) / switched (KPM)."))
panels.append(text_stat("Serving CU-UP (UE ${ue})", 14, 0, 5, 4,
                        "SELECT c.name || ' · since ' || strftime('%H:%M:%S', s.since, 'unixepoch', 'localtime') AS cuup "
                        "FROM serving s LEFT JOIN cuups c ON c.id = s.cuup WHERE s.ue = '${ue}' OR s.ue = '?' LIMIT 1",
                        "cuup", None, "value",
                        desc="CU-UP carrying the UE's downlink now, from the per-CU-UP DRB.PdcpSduVolumeDL in KPM."))
panels.append(text_stat("Last procedure time", 19, 0, 5, 4,
                        "SELECT procedure_ms FROM runs WHERE procedure_ms IS NOT NULL ORDER BY id DESC LIMIT 1",
                        "procedure_ms", None, "value", unit="ms",
                        desc="From 'moving N PDU sessions' to 'change of gNB-CU-UP complete' in the CU-CP log."))
panels.append(panel("Last run", "table", 9, 4, 15, 5,
                    [q("SELECT id AS run, mode, 'UE ' || COALESCE(NULLIF(ue,0),'any') AS ue, "
                       + SLICE_CASE.format(c="sst") + " AS slice, "
                       "COALESCE(metric || CASE cmp WHEN 'lt' THEN ' < ' ELSE ' > ' END || threshold || ' x' || consecutive, '') AS rule, "
                       "(SELECT name FROM cuups WHERE id = from_cuup) AS 'from', "
                       "COALESCE((SELECT name FROM cuups WHERE id = to_cuup), (SELECT name FROM cuups WHERE id = target_cuup), 'any other') AS 'to', "
                       "COALESCE(forwarding, '') AS forwarding, fwd_sdus AS forwarded, held_sdus AS held, held_ms AS 'held ms' "
                       "FROM runs ORDER BY id DESC LIMIT 1")],
                    options={"showHeader": True, "cellHeight": "sm"},
                    fieldConfig={"defaults": {"custom": {"align": "auto"}}, "overrides": []}))

panels.append(panel("Topology: where each UE is served", "nodeGraph", 0, 9, 12, 13,
                    [q("SELECT id, title, subtitle, mainstat, secondarystat, color, detail__role FROM nodes", ref="nodes"),
                     q("SELECT id, source, target, mainstat, color, thickness, strokedasharray FROM edges", ref="edges")],
                    description="UE -> DU edge: DL throughput (DU KPM). DU -> CU-UP edge: the CU-UP carrying the UE's "
                                "downlink. Orange: the target while a relocation is in flight.",
                    options={"nodes": {}, "edges": {}}))
panels.append(panel("Progress towards firing (current run)", "table", 12, 9, 12, 6,
                    [q("SELECT 'UE ' || ue AS ue, " + SLICE_CASE.format(c="sst") + " AS slice, metric, "
                       "round(value, 1) AS value, streak, needed, "
                       "strftime('%H:%M:%S', tstamp, 'unixepoch', 'localtime') AS at FROM progress ORDER BY ue, sst")],
                    options={"showHeader": True, "cellHeight": "sm"},
                    fieldConfig={"defaults": {}, "overrides": [
                        {"matcher": {"id": "byName", "options": "streak"},
                         "properties": [{"id": "custom.cellOptions", "value": {"type": "gauge", "mode": "basic"}},
                                        {"id": "min", "value": 0}, {"id": "max", "value": 3}]}]}))
panels.append(panel("Procedure steps (CU-CP / CU-UP logs)", "table", 12, 15, 12, 7,
                    [q("SELECT strftime('%H:%M:%f', tstamp, 'unixepoch', 'localtime') AS at, source, kind, text "
                       "FROM events WHERE run_id = (SELECT MAX(id) FROM runs) ORDER BY id")],
                    options={"showHeader": True, "cellHeight": "sm"},
                    fieldConfig={"defaults": {}, "overrides": [
                        {"matcher": {"id": "byName", "options": "at"}, "properties": [{"id": "custom.width", "value": 110}]},
                        {"matcher": {"id": "byName", "options": "source"}, "properties": [{"id": "custom.width", "value": 90}]},
                        {"matcher": {"id": "byName", "options": "kind"}, "properties": [{"id": "custom.width", "value": 100}]}]}))

thp_sql = ("SELECT k.tstamp AS time, " + SLICE_CASE.format(c="k.sst") + " AS metric, AVG(k.measure_value)/1000 AS value "
           "FROM KPM_MeasRecord k WHERE k.meas_name = 'DRB.UEThpDl' AND k.ran_ue_id = '${ue}' "
           "AND k.tstamp BETWEEN $__from/1000 AND $__to/1000 GROUP BY k.tstamp, k.sst ORDER BY k.tstamp")
panels.append(panel("DL throughput per slice, UE ${ue} (Mbit/s)", "timeseries", 0, 22, 12, 9,
                    [q(thp_sql, ds=KPM, kind="time series", time_cols=("time",))], ds=KPM,
                    fieldConfig={"defaults": {"unit": "Mbits", "custom": {"lineWidth": 2, "fillOpacity": 8}}, "overrides": []},
                    options={"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}}))
vol_sql = ("SELECT tstamp AS time, CASE cu_du_id WHEN 3585 THEN 'cuup_co' WHEN 3586 THEN 'cuup_e' ELSE 'CU-UP ' || cu_du_id END "
           "AS metric, SUM(measure_value) AS value FROM KPM_MeasRecord WHERE meas_name = 'DRB.PdcpSduVolumeDL' "
           "AND ngran_type = 'ngran_gNB_CUUP' AND tstamp BETWEEN $__from/1000 AND $__to/1000 "
           "GROUP BY tstamp, cu_du_id ORDER BY tstamp")
panels.append(panel("Downlink volume per CU-UP (the switch)", "timeseries", 12, 22, 12, 9,
                    [q(vol_sql, ds=KPM, kind="time series", time_cols=("time",))], ds=KPM,
                    fieldConfig={"defaults": {"unit": "short", "custom": {"lineWidth": 2, "fillOpacity": 15,
                                                                           "drawStyle": "line"}}, "overrides": []},
                    options={"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}}))
delay_sql = ("SELECT k.tstamp AS time, " + SLICE_CASE.format(c="k.sst") + " AS metric, AVG(k.measure_value)/10 AS value "
             "FROM KPM_MeasRecord k WHERE k.meas_name = 'DRB.PdcpSduDelayDl' AND k.ran_ue_id = '${ue}' "
             "AND k.tstamp BETWEEN $__from/1000 AND $__to/1000 GROUP BY k.tstamp, k.sst ORDER BY k.tstamp")
panels.append(panel("PDCP residency per slice, UE ${ue} (ms)", "timeseries", 0, 31, 12, 8,
                    [q(delay_sql, ds=KPM, kind="time series", time_cols=("time",))], ds=KPM,
                    fieldConfig={"defaults": {"unit": "ms", "custom": {"lineWidth": 2}}, "overrides": []},
                    options={"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}}))
rlc_sql = ("SELECT k.tstamp AS time, " + SLICE_CASE.format(c="k.sst") + " AS metric, AVG(k.measure_value)/1000 AS value "
           "FROM KPM_MeasRecord k WHERE k.meas_name = 'DRB.RlcSduDelayDl' AND k.ran_ue_id = '${ue}' "
           "AND k.tstamp BETWEEN $__from/1000 AND $__to/1000 GROUP BY k.tstamp, k.sst ORDER BY k.tstamp")
panels.append(panel("RLC residency per slice, UE ${ue} (ms)", "timeseries", 12, 31, 12, 8,
                    [q(rlc_sql, ds=KPM, kind="time series", time_cols=("time",))], ds=KPM,
                    fieldConfig={"defaults": {"unit": "ms", "custom": {"lineWidth": 2}}, "overrides": []},
                    options={"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}}))
panels.append(panel("Runs", "table", 0, 39, 24, 8,
                    [q("SELECT id AS run, strftime('%Y-%m-%d %H:%M:%S', started, 'unixepoch', 'localtime') AS started, mode, "
                       "state, 'UE ' || COALESCE(NULLIF(ue,0),'any') AS ue, " + SLICE_CASE.format(c="sst") + " AS slice, "
                       "COALESCE(metric || CASE cmp WHEN 'lt' THEN ' < ' ELSE ' > ' END || threshold || ' x' || consecutive, '') AS rule, "
                       "(SELECT name FROM cuups WHERE id = from_cuup) AS 'from', (SELECT name FROM cuups WHERE id = to_cuup) AS 'to', "
                       "round((fired - started), 1) AS 'to fire s', procedure_ms AS 'procedure ms', forwarding, "
                       "fwd_sdus AS forwarded, held_sdus AS held, held_ms AS 'held ms', note "
                       "FROM runs ORDER BY id DESC LIMIT 50")],
                    options={"showHeader": True, "cellHeight": "sm"},
                    fieldConfig={"defaults": {"mappings": STATE_MAP}, "overrides": [
                        {"matcher": {"id": "byName", "options": "state"},
                         "properties": [{"id": "custom.cellOptions", "value": {"type": "color-background"}}]}]}))

variables = [
    {"type": "constant", "name": "ctl", "query": CTL_URL, "hide": 2, "skipUrlSync": True},
    {"type": "query", "name": "ue", "label": "UE", "datasource": KPM, "refresh": 1,
     "query": "SELECT DISTINCT ran_ue_id AS __value, 'UE ' || ran_ue_id AS __text FROM UE_SLICE_MAP ORDER BY 1",
     "definition": "SELECT DISTINCT ran_ue_id AS __value, 'UE ' || ran_ue_id AS __text FROM UE_SLICE_MAP ORDER BY 1",
     "sort": 0},
    {"type": "custom", "name": "sst", "label": "Slice",
     "query": "any : 0,eMBB (SST 1) : 1,URLLC (SST 2) : 2,mIoT (SST 3) : 3"},
    {"type": "query", "name": "target", "label": "Target CU-UP", "datasource": CTL, "refresh": 1,
     "query": "SELECT id AS __value, name || ' (' || id || ')' AS __text FROM cuups UNION ALL "
              "SELECT -1 AS __value, 'any other' AS __text",
     "definition": "cuups", "sort": 0},
    {"type": "custom", "name": "metric", "label": "Metric",
     "query": "DL throughput kbit/s · DRB.UEThpDl : DRB.UEThpDl,"
              "PDCP residency 0.1 ms · DRB.PdcpSduDelayDl : DRB.PdcpSduDelayDl,"
              "RLC residency µs · DRB.RlcSduDelayDl : DRB.RlcSduDelayDl,"
              "RLC buffer bytes · DRB.RlcBufOccDl : DRB.RlcBufOccDl"},
    {"type": "custom", "name": "cmp", "label": "Fire when", "query": "above : gt,below : lt"},
    {"type": "textbox", "name": "threshold", "label": "Threshold", "query": "50000"},
    {"type": "textbox", "name": "consecutive", "label": "Reports in a row", "query": "3"},
    {"type": "custom", "name": "guard", "label": "Only while (guard)",
     "query": "no guard : none,RLC residency µs · DRB.RlcSduDelayDl : DRB.RlcSduDelayDl,"
              "RLC buffer bytes · DRB.RlcBufOccDl : DRB.RlcBufOccDl"},
    {"type": "custom", "name": "guard_cmp", "label": "Guard", "query": "below : lt,above : gt"},
    {"type": "textbox", "name": "guard_threshold", "label": "Guard threshold", "query": "5000"},
]


def fill_custom(v):
    """Grafana provisioning wants options/current for custom variables."""
    if v["type"] == "custom":
        opts = []
        for item in v["query"].split(","):
            text, _, value = item.partition(" : ")
            opts.append({"text": text.strip(), "value": (value or text).strip(), "selected": False})
        opts[0]["selected"] = True
        v["options"] = opts
        v["current"] = {"text": opts[0]["text"], "value": opts[0]["value"]}
    elif v["type"] in ("textbox", "constant"):
        v["current"] = {"text": v["query"], "value": v["query"]}
        v["options"] = [{"text": v["query"], "value": v["query"], "selected": True}]
    return v


dash = {
    "uid": "reloc-ctl",
    "title": "CU-UP relocation",
    "tags": ["relocation", "cu-up", "e2"],
    "timezone": "browser",
    "schemaVersion": 39,
    "version": 1,
    "refresh": "2s",
    "time": {"from": "now-5m", "to": "now"},
    "timepicker": {"refresh_intervals": ["1s", "2s", "5s", "10s", "30s"]},
    "editable": True,
    "liveNow": False,
    "templating": {"list": [fill_custom(v) for v in variables]},
    "links": [
        {"title": "▶ Arm trigger", "type": "link", "url": "${ctl}/arm", "includeVars": True, "keepTime": False,
         "targetBlank": False, "icon": "bolt", "asDropdown": False, "tags": [], "tooltip": "Start the trigger xApp with the settings above"},
        {"title": "⚡ Relocate now", "type": "link", "url": "${ctl}/now", "includeVars": True, "keepTime": False,
         "targetBlank": False, "icon": "bolt", "asDropdown": False, "tags": [], "tooltip": "Move the UE to the target on the next report"},
        {"title": "■ Stop", "type": "link", "url": "${ctl}/stop", "includeVars": True, "keepTime": False,
         "targetBlank": False, "icon": "info", "asDropdown": False, "tags": [], "tooltip": "Stop the running trigger"},
    ],
    "annotations": {"list": [
        {"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": True, "hide": True,
         "iconColor": "rgba(0, 211, 255, 1)", "name": "Annotations & Alerts", "type": "dashboard"},
        {"name": "Relocations", "enable": True, "iconColor": "#FF9830", "datasource": CTL,
         "target": q("SELECT tstamp AS time, source || ': ' || text AS text, kind AS tags FROM events "
                     "WHERE kind IN ('armed','fired','start','complete','switched','given_up') "
                     "AND tstamp BETWEEN $__from/1000 AND $__to/1000 ORDER BY tstamp", ref="Anno")},
    ]},
    "panels": panels,
}

out = sys.argv[1] if len(sys.argv) > 1 else "reloc-control.json"
with open(out, "w") as f:
    json.dump(dash, f, indent=2, ensure_ascii=False)
print("wrote", out, len(panels), "panels")
