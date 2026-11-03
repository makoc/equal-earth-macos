#!/usr/bin/env python3
"""Prepare the bundled Natural Earth layers for the political base map.

Natural Earth (https://www.naturalearthdata.com/) is in the public domain. The source
files are the 1:50 million GeoJSON exports from
https://github.com/nvkelso/natural-earth-vector/tree/master/geojson

Usage:
    python3 -I Tools/prepare_natural_earth.py <folder with downloaded .geojson> EqualEarthExplorer/Resources

The script keeps only the properties the app reads, rounds coordinates to 4 decimals
(about 11 m) and selects the labelled places: national capitals plus other cities with
at least 5 million inhabitants.
"""
import json
import os
import sys

MIN_CITY_POPULATION = 5_000_000


def rounded(coords):
    if not coords:
        return []
    if isinstance(coords[0], (int, float)):
        return [round(coords[0], 4), round(coords[1], 4)]
    return [rounded(c) for c in coords]


def write(path, features):
    collection = {"type": "FeatureCollection", "features": features}
    with open(path, "w", encoding="utf-8") as f:
        json.dump(collection, f, ensure_ascii=False, separators=(",", ":"))
    print(f"{os.path.basename(path)}: {len(features)} features, {os.path.getsize(path) / 1e6:.2f} MB")


def feature(geometry, properties):
    return {
        "type": "Feature",
        "properties": properties,
        "geometry": {"type": geometry["type"], "coordinates": rounded(geometry["coordinates"])},
    }


def load(folder, name):
    with open(os.path.join(folder, name + ".geojson"), encoding="utf-8") as f:
        return [x for x in json.load(f)["features"] if x.get("geometry")]


def main(source, target):
    countries = [
        feature(x["geometry"], {
            "name": x["properties"]["NAME"],
            "mapcolor7": x["properties"]["MAPCOLOR7"],
            "labelrank": x["properties"]["LABELRANK"],
            "label_x": x["properties"]["LABEL_X"],
            "label_y": x["properties"]["LABEL_Y"],
            "antarctica": x["properties"]["ADM0_A3"] == "ATA",
        })
        for x in load(source, "ne_50m_admin_0_countries")
    ]
    write(os.path.join(target, "ne_50m_admin_0_countries.geojson"), countries)

    lakes = [feature(x["geometry"], {"name": x["properties"].get("name")})
             for x in load(source, "ne_50m_lakes")]
    write(os.path.join(target, "ne_50m_lakes.geojson"), lakes)

    rivers = [feature(x["geometry"], {"name": x["properties"].get("name"), "scalerank": x["properties"]["scalerank"]})
              for x in load(source, "ne_50m_rivers_lake_centerlines")]
    write(os.path.join(target, "ne_50m_rivers_lake_centerlines.geojson"), rivers)

    states = [feature(x["geometry"], {"country": x["properties"]["ADM0_NAME"]})
              for x in load(source, "ne_50m_admin_1_states_provinces_lines")]
    write(os.path.join(target, "ne_50m_admin_1_states_provinces_lines.geojson"), states)

    places = []
    for x in load(source, "ne_50m_populated_places_simple"):
        p = x["properties"]
        capital = p["featurecla"] in ("Admin-0 capital", "Admin-0 capital alt")
        if capital or p["pop_max"] >= MIN_CITY_POPULATION:
            places.append(feature(x["geometry"], {
                "name": p["name"],
                "capital": capital,
                "population": p["pop_max"],
            }))
    write(os.path.join(target, "ne_50m_populated_places_selected.geojson"), places)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
