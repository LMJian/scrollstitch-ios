#!/usr/bin/env python3
"""Check local submission assets; never certify publication or Apple approval."""
from html.parser import HTMLParser
import json
from pathlib import Path
import sys
from urllib.parse import urlsplit
from prepare_store_site import render

ROOT = Path(__file__).resolve().parents[1]

class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.tags=[]; self.links=[]; self.language=None
    def handle_starttag(self, tag, attrs):
        attrs=dict(attrs); self.tags.append(tag)
        if tag=='html': self.language=attrs.get('lang')
        if tag=='a': self.links.append(attrs.get('href',''))
        if any(k.lower().startswith('on') for k in attrs):
            raise ValueError('Unexpected executable HTML handler')

def require(condition, message):
    if not condition: raise ValueError(message)

def check(root=ROOT):
    base=root/'docs/app-store'
    m=json.loads((base/'metadata.zh-Hans.json').read_text())
    status=json.loads((base/'release-status.json').read_text())
    require(m['schemaVersion']==status['schemaVersion']==1,'Unknown release schema')
    require(m['edition']=='appStore','Wrong release edition')
    for key,limit in [('displayName',30),('subtitle',30),('promotionalText',170),('description',4000)]:
        require(isinstance(m[key],str) and 0<len(m[key])<=limit,f'{key} exceeds field limits')
    require(0<len(m['keywords'].encode('utf-8'))<=100,'Keywords exceed 100 bytes')
    require(m['description']+'\n'==(base/'description.zh-Hans.txt').read_text(),'Description copy drift')
    require(m['price']=='free' and m['territories']==['CHN'],'Approved pricing or region changed')
    require(m['minimumIOS']=='27.0' and m['deviceFamilies']==['iPhone'],'Platform promise drift')
    require(m['copyright']=='2026 李明健','Copyright owner drift')
    require(m['supportEmail']=='limingjian.yy@gmail.com','Support email drift')
    require(m['reviewContact'].get('phone') is None,'Private review phone must not be published')
    require(m.get('reviewPhoneStatus')=='provided_privately','Private review contact status missing')
    require(m['iconRightsStatus']=='commercial_use_confirmed_by_owner','Artwork rights confirmation missing')
    for key in ('supportEmail','price','territories'):
        require(m[key]==status['decisions'][key],f'Decision mismatch: {key}')
    require(m['requiresLogin'] is False,'Unexpected login requirement')
    require(m['releaseMode']=='manual','Automatic release is not authorized')
    for name in ('privacy-answers.md','filing-preparation.md'):
        require((base/name).is_file(),'Missing submission preparation: '+name)
    for value in m['plannedURLs'].values():
        url=urlsplit(value)
        require(url.scheme=='https' and url.netloc=='lmjian.github.io' and url.path.startswith('/apps/scrollstitch/'),'Unexpected planned host/path')
    policies=[json.loads((root/p).read_text()) for p in ('Resources/ProductInfo.json','Resources/Store/ProductInfo.json')]
    require(policies[0]==policies[1],'Developer and Store privacy text drift')
    require(policies[0]['supportEmail']==m['supportEmail'],'App support email drift')
    if m['publicURLStatus']!='published_and_verified':
        require(all(p.get(k) is None for p in policies for k in ('supportURL','privacyURL')),'Unverified URL exposed in app')
    else:
        require(all(p.get(k)==m['plannedURLs'][name] for p in policies for k,name in [('supportURL','support'),('privacyURL','privacy')]),'Published app links differ from verified pages')
    generated=render(root)
    for name,expected in generated.items():
        text=(base/'site'/name).read_text()
        require(text==expected,'Generated page drift: '+name)
        page=Page(); page.feed(text)
        require(page.language=='zh-CN' and page.tags.count('main')==1 and page.tags.count('h1')==1,'Page structure invalid')
        require(not {'script','iframe','form','object','embed'}.intersection(page.tags),'Unexpected active content')
        require('mailto:'+m['supportEmail'] in page.links,'Missing usable email link')
        for link in page.links:
            parsed=urlsplit(link)
            require(parsed.scheme in ('','https','mailto'),'Unsafe link scheme')
            if not parsed.scheme:
                path=(base/'site'/parsed.path).resolve()
                require(path.is_relative_to((base/'site').resolve()) and path.exists(),'Broken local link')
        if name=='privacy.html':require('GitHub Pages' in text,'Hosting disclosure missing')
    require(m['mainlandFilingStatus']!='filed' or not any(p['id']=='mainland-filing' and p['status']!='complete' for p in status['pending']),'Filing contradicts pending evidence')
    return {'status':'passed','edition':'appStore','pages':len(generated),'keywordsBytes':len(m['keywords'].encode()),
            'publicURLStatus':m['publicURLStatus'],'boundary':'local material only; no publication, filing, runtime or Apple acceptance claim'}

if __name__=='__main__':
    try: print(json.dumps(check(),ensure_ascii=False))
    except (AssertionError,ValueError,KeyError,OSError) as error:
        print('FAIL: '+str(error),file=sys.stderr); raise SystemExit(1)
