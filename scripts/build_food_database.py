"""Build a compact, reproducible USDA SR Legacy macro table (public-domain data).
Source: https://fdc.nal.usda.gov/download-datasets/
Usage: python3 scripts/build_food_database.py /path/to/official-sr-legacy.zip
Keeps only foods with all four requested nutrients, never substitutes missing data with zero.
"""
import csv,io,json,math,sys,zipfile
from pathlib import Path
archive=zipfile.ZipFile(sys.argv[1])
def rows(file):
 name=next(x for x in archive.namelist() if x.endswith('/'+file))
 return csv.DictReader(io.TextIOWrapper(archive.open(name)))
root=Path(__file__).resolve().parents[1]
path=root/'Crumb/NutritionData/usda-foods.json'
curated=json.loads(path.read_text())[:16]
known={x['id'] for x in curated}
nutrients={}
for row in rows('food_nutrient.csv'):
 if row['nutrient_id'] in ['1008','1003','1004','1005'] and row['amount']:
  nutrients.setdefault(row['fdc_id'],{})[row['nutrient_id']]=float(row['amount'])
result=list(curated)
for row in rows('food.csv'):
 id=row['fdc_id'];n=nutrients.get(id,{})
 if id in known or not all(k in n and math.isfinite(n[k]) and n[k]>=0 for k in ['1008','1003','1004','1005']):continue
 desc=row['description']
 result.append(dict(id=id,name=desc,description=desc,aliases=[desc.lower()],kcal=n['1008'],protein=n['1003'],fat=n['1004'],carbs=n['1005'],countGrams=None,gramsPerMl=None))
result=curated+sorted(result[len(curated):],key=lambda x:x['name'])
path.write_text(json.dumps(result,separators=(',',':'),ensure_ascii=False))
print('USDA foods bundled:',len(result),'bytes:',path.stat().st_size)
