"""
Build the interactive multi-purpose haulage map (Leaflet, CDN tiles - needs
internet to view, everything else in the project works offline).

Produces:
  - map/haulage_map.html   standalone page
  - map/map_section.html   the same map as an embeddable <section> fragment
    (injected into index.html by 06_build_ebook.py)

Three toggleable layers over real (anonymised) GPS trip data, each aimed at
a different audience, each with its own legend:
  - Trip Volume     : dispatch/ops - where the haulage traffic actually is
  - Material Type   : production - what's moving out of each site
  - SARS Eligibility: compliance/audit - which sites' activity supports a
                      diesel-refund eligible-activity claim
Plus the top 40 haul routes as weighted lines (road-maintenance priority),
and a hover tooltip on every site so the map reads as interactive immediately.

Usage: python 08_build_map.py
"""
import json
import os
import pandas as pd

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANA = os.path.join(BASE, "data", "analysis")
MAPDIR = os.path.join(BASE, "map")
os.makedirs(MAPDIR, exist_ok=True)

sites = pd.read_csv(os.path.join(ANA, "map_sites.csv"))
routes = pd.read_csv(os.path.join(ANA, "map_routes.csv"))

# Bold, saturated colours (white-halo outline on markers keeps them legible
# against any basemap, light or dark).
MATERIAL_COLORS = {
    "Waste": "#5B5F66", "Top Soil": "#8B5A2B", "HGO": "#E4002B",
    "MGO": "#FF8C00", "LGO": "#00A3A1", "VLGO": "#6A3FA0",
}
MATERIAL_LABELS = {
    "Waste": "Waste (overburden/mullock)", "Top Soil": "Top soil",
    "HGO": "HGO (high-grade ore)", "MGO": "MGO (medium-grade ore)",
    "LGO": "LGO (low-grade ore)", "VLGO": "VLGO (very-low-grade ore)",
}
DEFAULT_MATERIAL_COLOR = "#002F6C"

ELIG_WASTE = {"color": "#5B5F66", "label": "Waste disposal — eligible"}
ELIG_TRANSPORT = {"color": "#00A3A1", "label": "Ore/material transport on-site — eligible"}
ELIG_REVIEW = {"color": "#E4002B", "label": "Unclassified — needs review"}

def material_color(m):
    return MATERIAL_COLORS.get(str(m), DEFAULT_MATERIAL_COLOR)

def eligibility_color(activity):
    a = str(activity)
    if "Waste" in a:
        return ELIG_WASTE["color"]
    if any(k in a for k in ("Stockpile", "Crusher", "Blast", "Dump", "Call Point")):
        return ELIG_TRANSPORT["color"]
    return ELIG_REVIEW["color"]

sites_j = []
for r in sites.itertuples():
    sites_j.append({
        "name": r.SiteName, "lat": r.Latitude, "lng": r.Longitude,
        "trips": int(r.TripCount), "equip": int(r.EquipmentCount),
        "avgMin": r.AvgTripMinutes, "material": str(r.TopMaterialType),
        "activity": str(r.TopEligibleActivity),
        "matColor": material_color(r.TopMaterialType),
        "eligColor": eligibility_color(r.TopEligibleActivity),
    })

routes_j = []
for r in routes.itertuples():
    routes_j.append({
        "from": [r.SourceLat, r.SourceLong], "to": [r.DestLat, r.DestLong],
        "trips": int(r.TripCount), "src": r.SourceSite, "dst": r.DestSite,
    })

max_trips = max(s["trips"] for s in sites_j)
max_route = max(r["trips"] for r in routes_j)
center_lat = sites["Latitude"].mean()
center_lng = sites["Longitude"].mean()

# Legend content per layer, built from materials/categories actually present
# in the data (avoids listing colours that never appear on the map).
present_materials = sorted(sites["TopMaterialType"].dropna().astype(str).unique())
material_legend_items = [
    {"color": material_color(m), "label": MATERIAL_LABELS.get(m, m)}
    for m in present_materials if m != "nan"
]
eligibility_legend_items = [ELIG_TRANSPORT, ELIG_WASTE, ELIG_REVIEW]

SITES_JSON = json.dumps(sites_j)
ROUTES_JSON = json.dumps(routes_j)
MATERIAL_LEGEND_JSON = json.dumps(material_legend_items)
ELIGIBILITY_LEGEND_JSON = json.dumps(eligibility_legend_items)

MAP_HTML = f"""
<div id="haulmap-controls" style="display:flex; gap:8px; flex-wrap:wrap; margin-bottom:10px;">
  <button class="maplayer-btn active" data-layer="trips">Trip Volume</button>
  <button class="maplayer-btn" data-layer="material">Material Type</button>
  <button class="maplayer-btn" data-layer="eligibility">SARS Eligibility</button>
  <label style="margin-left:auto; font-size:.82rem; color:#63666A; display:flex; align-items:center; gap:6px;">
    <input type="checkbox" id="haulmap-routes-toggle"> Show top 40 haul routes
  </label>
</div>
<div style="position:relative;">
  <div id="haulmap" style="height:520px; border-radius:8px; border:1px solid #e5e7eb;"></div>
  <div id="haulmap-legend" style="position:absolute; bottom:10px; left:10px; z-index:1000;
    background:rgba(255,255,255,.95); border-radius:8px; padding:10px 14px; box-shadow:0 2px 8px rgba(0,0,0,.15);
    font-size:.78rem; color:#1a202c; max-width:260px;"></div>
</div>
<p style="font-size:.8rem; color:#63666A; margin-top:8px;">
  {len(sites_j)} haulage sites · {sites['TripCount'].sum():,} trips · real GPS coordinates
  (site/company identity kept fictional — see case-study note — so the basemap below is
  intentionally label-free: no place names, only terrain/road geometry for genuine
  ops/dispatch use). Hover a site for a quick summary, click for full detail.
  <strong>Data-quality note:</strong> the source system's Lat/Long columns are transposed
  (the "Lat" column holds longitude values and vice versa) — corrected here.
  Map requires an internet connection to load street tiles.
</p>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"
  integrity="sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY=" crossorigin=""/>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"
  integrity="sha256-20nQCchB9co0qIjJZRGuk2/Z9VM+kNiyxNV1lvTlZBo=" crossorigin=""></script>
<script>
(function() {{
  var sites = {SITES_JSON};
  var routes = {ROUTES_JSON};
  var maxTrips = {max_trips};
  var maxRoute = {max_route};
  var materialLegend = {MATERIAL_LEGEND_JSON};
  var eligibilityLegend = {ELIGIBILITY_LEGEND_JSON};

  var map = L.map('haulmap').setView([{center_lat:.6f}, {center_lng:.6f}], 14);
  // Label-free basemap (CartoDB Voyager, no-labels variant): keeps real terrain/road
  // colour and contrast for genuine ops usefulness, without the place-name text overlay
  // that would otherwise identify the real site on a standard OSM/Positron tile.
  L.tileLayer('https://{{s}}.basemaps.cartocdn.com/rastertiles/voyager_nolabels/{{z}}/{{x}}/{{y}}{{r}}.png', {{
    attribution: '&copy; OpenStreetMap contributors &copy; CARTO', maxZoom: 19, subdomains: 'abcd'
  }}).addTo(map);

  var markers = [];
  var routeLines = [];
  var currentLayer = 'trips';

  function radius(trips) {{ return 5 + 22 * Math.sqrt(trips / maxTrips); }}

  function colorFor(s, layer) {{
    if (layer === 'material') return s.matColor;
    if (layer === 'eligibility') return s.eligColor;
    return '#0072CE';
  }}

  sites.forEach(function(s) {{
    var m = L.circleMarker([s.lat, s.lng], {{
      radius: radius(s.trips), color: '#ffffff', weight: 2,
      fillColor: colorFor(s, 'trips'), fillOpacity: 0.9
    }}).addTo(map);
    m.bindTooltip(
      '<b>' + s.name + '</b><br>' + s.trips.toLocaleString() + ' trips',
      {{ direction: 'top', sticky: true }}
    );
    m.bindPopup(
      '<b>' + s.name + '</b><br>' +
      s.trips.toLocaleString() + ' trips &middot; ' + s.equip + ' equipment<br>' +
      'Avg trip: ' + s.avgMin + ' min<br>' +
      'Top material: ' + s.material + '<br>' +
      'Activity: ' + s.activity
    );
    markers.push({{marker: m, site: s}});
  }});

  routes.forEach(function(r) {{
    var line = L.polyline([r.from, r.to], {{
      color: '#E4002B', weight: 1 + 6 * (r.trips / maxRoute), opacity: 0.6
    }});
    line.bindTooltip(r.src + ' &rarr; ' + r.dst + '<br>' + r.trips.toLocaleString() + ' trips', {{ sticky: true }});
    routeLines.push(line);
  }});

  function swatch(color, label) {{
    return '<div style="display:flex;align-items:center;gap:6px;margin:3px 0;">' +
      '<span style="width:12px;height:12px;border-radius:50%;background:' + color +
      ';border:1.5px solid #fff;box-shadow:0 0 0 1px #ccc;display:inline-block;flex:none;"></span>' +
      '<span>' + label + '</span></div>';
  }}

  function renderLegend(layer) {{
    var el = document.getElementById('haulmap-legend');
    var html = '';
    if (layer === 'trips') {{
      html += '<div style="font-weight:700;margin-bottom:4px;">Trip volume</div>';
      html += '<div style="display:flex;align-items:center;gap:8px;margin:4px 0;">' +
        '<span style="width:10px;height:10px;border-radius:50%;background:#0072CE;border:1.5px solid #fff;box-shadow:0 0 0 1px #ccc;display:inline-block;"></span>' +
        '<span>Fewer trips</span></div>';
      html += '<div style="display:flex;align-items:center;gap:8px;margin:4px 0;">' +
        '<span style="width:26px;height:26px;border-radius:50%;background:#0072CE;border:1.5px solid #fff;box-shadow:0 0 0 1px #ccc;display:inline-block;"></span>' +
        '<span>More trips (bubble size)</span></div>';
    }} else if (layer === 'material') {{
      html += '<div style="font-weight:700;margin-bottom:4px;">Dominant material moved</div>';
      materialLegend.forEach(function(it) {{ html += swatch(it.color, it.label); }});
    }} else {{
      html += '<div style="font-weight:700;margin-bottom:4px;">SARS eligible-activity basis</div>';
      eligibilityLegend.forEach(function(it) {{ html += swatch(it.color, it.label); }});
    }}
    el.innerHTML = html;
  }}

  function setLayer(layer) {{
    currentLayer = layer;
    markers.forEach(function(o) {{
      o.marker.setStyle({{ fillColor: colorFor(o.site, layer) }});
    }});
    renderLegend(layer);
  }}

  document.querySelectorAll('.maplayer-btn').forEach(function(btn) {{
    btn.addEventListener('click', function() {{
      document.querySelectorAll('.maplayer-btn').forEach(function(b) {{ b.classList.remove('active'); }});
      btn.classList.add('active');
      setLayer(btn.dataset.layer);
    }});
  }});

  document.getElementById('haulmap-routes-toggle').addEventListener('change', function(e) {{
    if (e.target.checked) {{ routeLines.forEach(function(l) {{ l.addTo(map); }}); }}
    else {{ routeLines.forEach(function(l) {{ map.removeLayer(l); }}); }}
  }});

  renderLegend('trips');
}})();
</script>
<style>
.maplayer-btn {{ background:#fff; border:1px solid #d1d9e0; color:#002F6C; border-radius:6px;
  padding:7px 14px; font-size:.82rem; font-weight:600; cursor:pointer; }}
.maplayer-btn:hover {{ background:#f0f4f8; }}
.maplayer-btn.active {{ background:#002F6C; color:#fff; border-color:#002F6C; }}
</style>
"""

# Standalone page
standalone = f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Kalahari Petroleum — Haulage Map</title>
<style>body{{font-family:'Segoe UI',system-ui,sans-serif;max-width:1000px;margin:24px auto;padding:0 16px;color:#1a202c;}}
h1{{color:#002F6C;}}</style></head><body>
<h1>Haulage &amp; Site Activity Map</h1>
<p><a href="../index.html">&larr; Back to the data story</a></p>
{MAP_HTML}
</body></html>
"""
with open(os.path.join(MAPDIR, "haulage_map.html"), "w", encoding="utf-8") as f:
    f.write(standalone)

with open(os.path.join(MAPDIR, "map_section.html"), "w", encoding="utf-8") as f:
    f.write(MAP_HTML)

print(f"map: {os.path.join(MAPDIR, 'haulage_map.html')}")
print(f"map section: {os.path.join(MAPDIR, 'map_section.html')} ({len(sites_j)} sites, {len(routes_j)} routes)")
print(f"materials in legend: {present_materials}")
