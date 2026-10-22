#!/usr/bin/env python3
"""Converte DurrRobotTypesFiles.xlsx (da instalação do DXQ3D.onsite) em robots.json para o CellStudio."""
import json, sys, openpyxl

src = sys.argv[1]
dst = sys.argv[2]
ws = openpyxl.load_workbook(src, data_only=True)["RobotFileAssignment"]
header = [str(h).replace("\n", "") if h else "" for h in next(ws.iter_rows(min_row=1, max_row=1, values_only=True))]
col = {h: i for i, h in enumerate(header)}

def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None

robots = []
for r in ws.iter_rows(min_row=3, values_only=True):
    kind, name = r[col["MachineData.RobotType"]], r[col["Description"]]
    if not kind or not name:
        continue
    g = lambda k: num(r[col[k]]) if k in col else None
    links = {k: r[col[k + "_File"]].replace("\\", "/") for k in ("K1", "K2", "K3", "K4", "K5", "K5_1", "K6", "K7") if r[col[k + "_File"]]}
    robots.append({
        "name": name,
        "kind": kind,
        "a1": g("MachineData.MainJoints[0].DhParameters.DisplacementAlongX") or 0,
        "theta1": g("MachineData.MainJoints[0].DhParameters.RotationAroundZ") or 0,
        "a2": g("MachineData.MainJoints[1].DhParameters.DisplacementAlongX") or 0,
        "theta2": g("MachineData.MainJoints[1].DhParameters.RotationAroundZ") or 0,
        "a3": g("MachineData.MainJoints[2].DhParameters.DisplacementAlongX") or 0,
        "d3": g("MachineData.MainJoints[2].DhParameters.DisplacementAlongZ") or 0,
        "d4": g("MachineData.MainJoints[3].DhParameters.DisplacementAlongZ") or 0,
        "d5": g("MachineData.MainJoints[4].DhParameters.DisplacementAlongZ") or 0,
        "robotFile": (r[col["RobotFileName"]] or "").replace("\\", "/") or None,
        "linkFiles": links,
        "auxAssignment": r[col["AuxJointsAssignment"]] if "AuxJointsAssignment" in col else None,
    })
json.dump(robots, open(dst, "w"), indent=1, ensure_ascii=False)
print(len(robots), "robôs ->", dst)

# trilhos/eixos auxiliares (aba AuxJointsFileAssignment)
wa = openpyxl.load_workbook(src, data_only=True)["AuxJointsFileAssignment"]
h2 = [str(h).replace("\n", "") if h else "" for h in next(wa.iter_rows(min_row=1, max_row=1, values_only=True))]
rails = []
for r in wa.iter_rows(min_row=3, values_only=True):
    d = {k: v for k, v in zip(h2, r) if v is not None and k}
    if not d.get("AuxJointType") or not d.get("SledFileName"): continue
    f = lambda k: float(d.get(k) or 0)
    rails.append({
        "type": d["AuxJointType"],
        "preA": f("MachineData.AuxJoints[0].PrelinkFrame.A"), "preB": f("MachineData.AuxJoints[0].PrelinkFrame.B"),
        "preC": f("MachineData.AuxJoints[0].PrelinkFrame.C"),
        "sled": d["SledFileName"].replace("\\", "/"), "sledWidth": f("SledWidth"),
        "rail1500": (d.get("RailFileName1500mm") or "").replace("\\", "/"),
        "rail2000": (d.get("RailFileName2000mm") or "").replace("\\", "/"),
        "railTypeId": d.get("DefaultRailTypeId"), "singlePart": bool(d.get("SinglePart")),
        "railOffset": [f("RailOffsetXmm"), f("RailOffsetYmm"), f("RailOffsetZmm"), f("RailOffsetAdegree"), f("RailOffsetBdegree"), f("RailOffsetCdegree")],
        "sledOffset": [f("SledOffsetXmm"), f("SledOffsetYmm"), f("SledOffsetZmm"), f("SledOffsetAdegree"), f("SledOffsetBdegree"), f("SledOffsetCdegree")],
    })
rp = dst.replace("robots.json", "rails.json")
json.dump(rails, open(rp, "w"), indent=1, ensure_ascii=False)
print(len(rails), "trilhos ->", rp)
