"""Compose App Store marketing frames from raw simulator screenshots.
Usage: python3 compose.py RAW_DIR OUT_DIR   (needs Pillow; FONT env overrides the font)
"""
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os, sys
RAW, OUT = sys.argv[1], sys.argv[2]
F=os.environ.get("FONT", "/System/Library/Fonts/SFNS.ttf")
def font(sz,w):
    f=ImageFont.truetype(F,sz)
    try:
        axes=f.get_variation_axes()
        f.set_variation_by_axes([w if a['name'] in (b'Weight','Weight') else a['default'] for a in axes])
    except Exception: pass
    return f
COPY={
 'en':[('map','See every dead zone','A live Wi-Fi heatmap of every room'),
       ('perspective','Your home in 3D','Built from a LiDAR room scan'),
       ('inspector',"Inspect any spot's signal",'Strength, speed and what it is good for'),
       ('optimizer','Plan the perfect mesh setup','Find the best place for each satellite'),
       ('equipment','Matched to your equipment','Wi-Fi standard, bands and wall materials')],
 'pt':[('map','Veja cada zona morta','Mapa de Wi-Fi de cada divisão'),
       ('perspective','A sua casa em 3D','Criada a partir de um scan LiDAR'),
       ('inspector','Analise o sinal em qualquer ponto','Força, velocidade e para que serve'),
       ('optimizer','Planeie a rede mesh ideal','Encontre o melhor local para cada satélite'),
       ('equipment','Ajustado ao seu equipamento','Norma Wi-Fi, bandas e materiais das paredes')],
}
def grad(W,H):
    top=(8,20,38); bot=(10,92,84)
    im=Image.new('RGB',(W,H)); d=ImageDraw.Draw(im)
    for y in range(H):
        t=y/H; d.line([(0,y),(W,y)],fill=tuple(int(top[i]+(bot[i]-top[i])*t) for i in range(3)))
    glow=Image.new('L',(W,H),0); ImageDraw.Draw(glow).ellipse([W*0.1,H*0.25,W*0.9,H*0.85],fill=70)
    glow=glow.filter(ImageFilter.GaussianBlur(W//6))
    return Image.composite(Image.new('RGB',(W,H),(30,170,140)),im,glow)
def wrap(d,text,f,maxw):
    words=text.split(); lines=[]; cur=''
    for w in words:
        t=(cur+' '+w).strip()
        if d.textlength(t,font=f)<=maxw: cur=t
        else: lines.append(cur); cur=w
    lines.append(cur); return lines
def make(shot,head,sub,W,H,out,ipad):
    bg=grad(W,H); d=ImageDraw.Draw(bg)
    hf=font(int(W*(0.062 if ipad else 0.085)),800); sf=font(int(W*(0.03 if ipad else 0.042)),500)
    y=int(H*0.05)
    for l in wrap(d,head,hf,W*0.86):
        d.text((W/2,y),l,font=hf,fill='white',anchor='ma'); y+=int(hf.size*1.18)
    y+=int(H*0.008)
    for l in wrap(d,sub,sf,W*0.86):
        d.text((W/2,y),l,font=sf,fill=(190,230,220),anchor='ma'); y+=int(sf.size*1.3)
    top=y+int(H*0.035)
    sc=Image.open(shot).convert('RGB')
    sw=int(W*0.80); sh=int(sw*sc.height/sc.width)
    sc=sc.resize((sw,sh),Image.LANCZOS)
    bez=int(sw*0.028); r=int(sw*(0.06 if ipad else 0.13))
    fw,fh=sw+2*bez,sh+2*bez; x=(W-fw)//2
    sh_l=Image.new('L',(W,H),0); ImageDraw.Draw(sh_l).rounded_rectangle([x,top+20,x+fw,top+20+fh],r+bez,fill=150)
    sh_l=sh_l.filter(ImageFilter.GaussianBlur(40)); bg=Image.composite(Image.new('RGB',(W,H),(0,0,0)),bg,sh_l)
    d=ImageDraw.Draw(bg)
    d.rounded_rectangle([x,top,x+fw,top+fh],r+bez,fill=(18,18,20),outline=(70,74,80),width=max(3,bez//6))
    m=Image.new('L',(sw,sh),0); ImageDraw.Draw(m).rounded_rectangle([0,0,sw,sh],r,fill=255)
    bg.paste(sc,(x+bez,top+bez),m)
    bg.convert('RGB').save(out,'PNG')
for lang,items in COPY.items():
    for dev,(W,H) in {'iphone':(1320,2868),'ipad':(2064,2752)}.items():
        od=f'{OUT}/{lang}/{dev}'; os.makedirs(od,exist_ok=True)
        for i,(s,h,sub) in enumerate(items,1):
            make(f'{RAW}/{dev}/{s}.png',h,sub,W,H,f'{od}/{i:02d}_{s}.png',dev=='ipad')
