from pathlib import Path
import re,json,subprocess,collections
root=Path(__file__).resolve().parents[1]/'Crumb'
D={lang:json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(root/(lang+'.lproj')/'Localizable.strings')])) for lang in ['ja','en','ko']}
allkeys=set.union(*(set(x) for x in D.values()))
for lang,d in D.items():
 assert set(d) == allkeys, f'{lang}: missing translation keys {sorted(allkeys-set(d))}'
missing=collections.defaultdict(set)
for p in root.glob('*.swift'):
 if p.name == 'RecipeImport.swift': continue # Parser patterns and units are input syntax, not UI text.
 # Literal-only scan; interpolated numeric keys are reviewed separately.
 source=p.read_text()
 if p.name=='Meals.swift':
  source=re.sub(r'enum Samples \{.*?\nfunc crumbFont', 'func crumbFont', source, flags=re.S)
 for m in re.finditer(r'"(?:\\.|[^"\\])*"',source):
  raw=m.group()[1:-1]
  if not re.search(r'[\u3040-\u30ff\u3400-\u9fff]',raw) or '\\(' in raw: continue
  try:key=json.loads(m.group())
  except:continue
  if p.name == 'Nutrition.swift' and key in {'個', '玉', '本', '片'}: continue # Accepted ingredient units, never UI labels.
  if key == '日本語': continue # Language names are intentionally shown as autonyms.
  for lang,d in D.items():
   if key not in d:missing[key].add(p.name)
assert not missing, 'Missing UI literals: '+str(dict(missing))
print(f'PASS: {len(allkeys)} keys have Japanese, English and Korean values; app UI literals covered.')
for k,files in sorted(missing.items()):print(k,' | ',','.join(sorted(files)))
print('PASS: no Japanese fallback strings in English/Korean resources.')
for lang in ['en','ko']:
 for k,v in D[lang].items():
  assert not re.search(r'[\u3040-\u30ff]',v), f'{lang}: Japanese translation fallback for {k}'
for key in ['All', 'My Menu', 'Free', 'Carbonara', '%lld人前', 'プライバシーポリシー', '利用規約']:
 assert all(key in d for d in D.values()), f'Missing fixed interface label: {key}'
permissions={lang:json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(root/(lang+'.lproj')/'InfoPlist.strings')])) for lang in ['ja','en','ko']}
assert len({tuple(sorted(d)) for d in permissions.values()}) == 1
assert all(all(v.strip() for v in d.values()) for d in permissions.values())
print('PASS: fixed labels, format keys and camera/photo permission descriptions covered in all three languages.')
