#!/usr/bin/env python3
"""Render self-contained support/privacy pages from reviewed release text. No network writes."""
import argparse
from html import escape
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

STYLE = '''
:root{color-scheme:light dark;--bg:#f6f3ee;--ink:#262528;--muted:#686369;--paper:#fffdf9;--accent:#a63643;--line:#e6dfd7}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:17px/1.85 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif}
header,main,footer{max-width:880px;margin:auto;padding:28px 26px}header{display:flex;justify-content:space-between;gap:20px;border-bottom:1px solid var(--line)}
a{color:var(--accent);text-underline-offset:4px}header a{text-decoration:none}nav{display:flex;flex-wrap:wrap;gap:20px;font-size:14px}.brand{font-size:21px;font-weight:750;letter-spacing:.12em}
main{padding-top:54px;padding-bottom:60px}h1{font-size:clamp(30px,6vw,48px);letter-spacing:-.03em;line-height:1.25;margin:12px 0 24px}h2{font-size:21px;margin:0 0 10px}p{margin:0 0 16px}.eyebrow{font-size:13px;font-weight:650;letter-spacing:.1em;color:var(--accent)}
.lead{font-size:19px;color:var(--muted);max-width:38em}.card{padding:26px;margin:20px 0;background:var(--paper);border:1px solid var(--line);border-radius:20px}
.tag{font-size:13px;color:var(--muted)}.button{display:inline-block;border-radius:999px;padding:10px 22px;background:var(--accent);color:white;text-decoration:none;font-weight:600;margin:8px 0}
ul{padding-left:1.3em}li{margin:8px 0}.note{color:var(--muted);font-size:14px}footer{border-top:1px solid var(--line);font-size:13px;color:var(--muted);padding-bottom:40px}
a:focus-visible{outline:3px solid var(--accent);outline-offset:5px}@media(prefers-color-scheme:dark){:root{--bg:#1d1c1f;--ink:#f3eee8;--muted:#b8b0b0;--paper:#29262a;--accent:#ed9aa4;--line:#494148}.button{color:#261317}}
@media(max-width:480px){header{flex-direction:column;gap:12px}main{padding-top:36px}.card{padding:20px}nav{gap:16px}}
'''

def render(root=ROOT):
    metadata = json.loads((root/'docs/app-store/metadata.zh-Hans.json').read_text())
    product = json.loads((root/'Resources/Store/ProductInfo.json').read_text())
    email = escape(metadata['supportEmail'], quote=True)
    owner = escape(metadata['copyright'])
    date = escape(product['effectiveDate'])

    def page(title, content):
        return f'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer"><meta name="description" content="卷轴：滚动截图、多图拼接和调休闹钟。隐私说明与联系支持。">
<title>{escape(title)} · 卷轴</title><style>{STYLE}</style></head><body>
<header><a class="brand" href="./">卷轴</a><nav aria-label="网站导航"><a href="./">功能</a><a href="support.html">联系与支持</a><a href="privacy.html">隐私政策</a></nav></header>
<main>{content}</main><footer>© {owner} · <a href="mailto:{email}">{email}</a></footer></body></html>
'''

    privacy = '<p class="eyebrow">隐私与数据</p><h1>你的内容，留在本机。</h1>'
    privacy += f'<p class="lead">本政策适用于卷轴 iPhone App 的滚动截图、多图拼接与调休闹钟。开发者：李明健。更新日期：{date}。</p>'
    for section in product['sections']:
        privacy += f'<section class="card"><h2>{escape(section["title"])}</h2><p>{escape(section["body"])}</p></section>'
    privacy += f'''<section class="card"><h2>你的选择与隐私请求</h2><p>可在 iOS 设置中管理录屏、添加照片、通知和闹钟相关权限，在年度安排中关闭自动检查，并在 App 中管理本机作品与闹钟。离线处理不要求注册账号。</p><p>如需了解、纠正或删除你主动发送给开发者的反馈资料，请联系 <a href="mailto:{email}">{email}</a>。本机素材不会自动上传，因此开发者无法在服务器替你读取或删除这些本机文件。处理支持请求后不再主动使用相关资料；法律要求、必要的争议处理和邮件服务备份可能影响最终删除时间。</p></section>
<section class="card"><h2>托管服务与政策更新</h2><p>本支持网站及年度 JSON 文件由 GitHub Pages 托管，网络请求可能经过境外服务。GitHub 会为安全目的记录访问者 IP；我们不向年度下载接口附加账号、图片或闹钟内容，也不部署广告、跟踪脚本或分析 Cookie。</p><p>可查阅 <a href="https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages">GitHub Pages 数据收集说明</a>及 <a href="https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement">GitHub 隐私声明</a>。如数据处理方式发生变化，会同步更新 App 内说明和本页，并按适用要求提供提示或征求同意。</p></section>'''
    support = f'''<p class="eyebrow">联系与支持</p><h1>有问题，告诉我。</h1><p class="lead">请说明你在做什么，以及在哪一步遇到问题。卷轴无需注册，图片处理在你的 iPhone 上完成。</p>
<a class="button" href="mailto:{email}">邮件联系开发者</a><p class="note">李明健 · {email}</p>
<section class="card"><h2>反馈时提供这些信息</h2><ul><li>卷轴版本、iOS 版本、设备型号。</li><li>所用功能、具体操作步骤、看到的错误提示。</li><li>预期结果与实际结果。若有截图，请先遮挡私人信息。</li></ul><p>无需发送 Apple 账号、密码、身份证件或完整私人录屏。诊断文件仅在你选择生成并分享后发出。</p></section>
<section class="card"><h2>滚动截图没有保存到相册</h2><p>先在卷轴的作品中查看结果，再检查 iOS 的添加照片权限。若显示“保存结果不确定”，先确认相册中是否已有成品，再决定是否重试。不要重复启动录制来覆盖原作品。</p><p>开始后等待系统共享提示与控制面板收起，再沿同一方向轴缓慢滚动；换页先暂停，切换后继续。受系统保护的内容可能无法截取。</p></section>
<section class="card"><h2>拼图如何调整与导出</h2><p>选择 2–20 张图片后，可调整顺序、裁剪、间距和背景。生成后在预览中保存 PNG/JPEG 或系统分享。超出处理预算时会提示缩小；拒绝相册权限仍可分享。</p></section>
<section class="card"><h2>闹钟和年度安排</h2><p>所有时间固定为北京时间。法定工作日规则依赖已保存的年度安排；缺少某年的数据时不会推测。可在“年度安排”中查看、手动检查更新或关闭自动检查，网络失败时继续使用已有有效数据。</p><p>最多预排未来 90 天内最近 64 次。请关注实际覆盖日期，在到期前打开卷轴补齐；后台刷新不保证执行。不要隐藏 App 或为它单独设置 Face ID／密码锁，系统可能限制闹钟。已排程的闹钟可离线执行。</p></section>
<section class="card"><h2>删除和隐私</h2><p>清除当前拼图不会删除相册原图或已导出的成品；删除闹钟会尝试同步移除系统排程。滚动作品目前保留在本机，清理全部本机数据前请先导出所需结果再卸载应用。可在应用内“隐私与数据”或 <a href="privacy.html">隐私政策</a>查看数据流向与联系渠道。</p></section>'''
    home = '''<p class="eyebrow">卷轴 · IPHONE 工具</p><h1>滚过的内容，<br>一张留下。</h1><p class="lead">滚动长截图、多图拼接与调休闹钟。图片在本机处理，日常安排有据可查。</p><p class="tag">iOS 27+ · 免费 · 无需注册 · 正在准备上架</p>
<section class="card"><h2>滚动截图</h2><p>控制中心开始，确认系统屏幕共享，完成后自动整理成图并保存照片。支持同一方向轴内往返、暂停和接下一页，不录制声音。</p></section>
<section class="card"><h2>多图拼接</h2><p>选择 2–20 张图片，自由调整顺序、裁剪、间距与背景，预览后保存或分享。</p></section>
<section class="card"><h2>调休闹钟</h2><p>按中国法定工作日安排提醒，支持年度数据更新和单日例外。时间固定为北京时间；已保存数据和已排程闹钟可离线使用，请在覆盖日期结束前打开 App 补齐。</p></section>
<a class="button" href="support.html">联系与支持</a><p class="note">正式下载入口将在发布后补充。目前没有 App Store 下载或 TestFlight 邀请链接。</p>'''
    return {'index.html':page('功能',home),'privacy.html':page('隐私政策',privacy),'support.html':page('联系与支持',support)}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args=parser.parse_args()
    destination=ROOT/'docs/app-store/site'
    for name, content in render().items():
        path=destination/name
        if args.check:
            if not path.exists() or path.read_text()!=content:
                raise SystemExit('Stale generated site: '+name)
        else:
            destination.mkdir(parents=True,exist_ok=True)
            path.write_text(content)
    print('PASS: generated privacy/support site is current' if args.check else 'Prepared three static HTML pages; no deployment performed')

if __name__=='__main__': main()
