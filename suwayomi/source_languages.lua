-- Boundary: SourceLanguages.
--
-- Responsibility: Resolve Suwayomi source language codes to display labels.
-- Owned state: Keeps a static copy of Suwayomi WebUI's native language labels.
-- Dependencies: None.
-- External data: Source language codes from Suwayomi are treated as untrusted strings.

local SourceLanguages = {}

local RAW_LABELS = [=[
es-419	Español (Latinoamérica)
pt-pt	Português (Portugal)
pt-br	Português (Brasil)
pt-BR	Português (Brasil)
zh-Hans	中文 (HANS)
zh-Hant	中文 (HANT)
zh-rhk	中文 (RHK)
zh-rtw	中文 (RTW)
fil	Filipino
sh	srpskohrvatski
nb-NO	Norsk bokmål
aa	Afaraf
ab	аҧсуа бызшәа
ae	avesta
af	Afrikaans
ak	Akan
am	አማርኛ
an	aragonés
ar	اَلْعَرَبِيَّةُ
as	অসমীয়া
av	авар мацӀ
ay	aymar aru
az	azərbaycan dili
ba	башҡорт теле
be	беларуская мова
bg	български език
bi	Bislama
bm	bamanankan
bn	বাংলা
bo	བོད་ཡིག
br	brezhoneg
bs	bosanski jezik
ca	Català
ce	нохчийн мотт
ch	Chamoru
co	corsu
cr	ᓀᐦᐃᔭᐍᐏᐣ
cs	čeština
cu	ѩзыкъ словѣньскъ
cv	чӑваш чӗлхи
cy	Cymraeg
da	Dansk
de	Deutsch
dv	ދިވެހި
dz	རྫོང་ཁ
ee	Eʋegbe
el	Ελληνικά
en	English
eo	Esperanto
es	Español
et	eesti
eu	euskara
fa	فارسی
ff	Fulfulde
fi	suomi
fj	vosa Vakaviti
fo	Føroyskt
fr	Français
fy	Frysk
ga	Gaeilge
gd	Gàidhlig
gl	galego
gn	Avañe'ẽ
gu	ગુજરાતી
gv	Gaelg
ha	هَوُسَ
he	עברית
hi	हिन्दी
ho	Hiri Motu
hr	Hrvatski
ht	Kreyòl ayisyen
hu	magyar
hy	Հայերեն
hz	Otjiherero
ia	Interlingua
id	Bahasa Indonesia
ie	Interlingue
ig	Asụsụ Igbo
ii	ꆈꌠ꒿ Nuosuhxop
ik	Iñupiaq
io	Ido
is	Íslenska
it	Italiano
iu	ᐃᓄᒃᑎᑐᑦ
ja	日本語
jv	basa Jawa
ka	ქართული
kg	Kikongo
ki	Gĩkũyũ
kj	Kuanyama
kk	қазақ тілі
kl	kalaallisut
km	ខេមរភាសា
kn	ಕನ್ನಡ
ko	한국어
kr	Kanuri
ks	कश्मीरी
ku	Kurdî
kv	коми кыв
kw	Kernewek
ky	Кыргызча
la	latine
lb	Lëtzebuergesch
lg	Luganda
li	Limburgs
ln	Lingála
lo	ພາສາລາວ
lt	lietuvių kalba
lu	Kiluba
lv	latviešu valoda
mg	fiteny malagasy
mh	Kajin M̧ajeļ
mi	te reo Māori
mk	македонски јазик
ml	മലയാളം
mn	Монгол хэл
mr	मराठी
ms	Bahasa Melayu
mt	Malti
my	ဗမာစာ
na	Dorerin Naoero
nb	Norsk bokmål
nd	isiNdebele
ne	नेपाली
ng	Owambo
nl	Nederlands
nn	Norsk nynorsk
no	Norsk
nr	isiNdebele
nv	Diné bizaad
ny	chiCheŵa
oc	occitan
oj	ᐊᓂᔑᓈᐯᒧᐎᓐ
om	Afaan Oromoo
or	ଓଡ଼ିଆ
os	ирон æвзаг
pa	ਪੰਜਾਬੀ
pi	पाऴि
pl	Polski
ps	پښتو
pt	Português
qu	Runa Simi
rm	rumantsch grischun
rn	Ikirundi
ro	Română
ru	Русский
rw	Ikinyarwanda
sa	संस्कृतम्
sc	sardu
sd	सिन्धी
se	Davvisámegiella
sg	yângâ tî sängö
si	සිංහල
sk	slovenčina
sl	slovenščina
sm	gagana fa'a Samoa
sn	chiShona
so	Soomaaliga
sq	Shqip
sr	српски језик
ss	SiSwati
st	Sesotho
su	Basa Sunda
sv	Svenska
sw	Kiswahili
ta	தமிழ்
te	తెలుగు
tg	тоҷикӣ
th	ไทย
ti	ትግርኛ
tk	Türkmençe
tl	Wikang Tagalog
tn	Setswana
to	faka Tonga
tr	Türkçe
ts	Xitsonga
tt	татар теле
tw	Twi
ty	Reo Tahiti
ug	ئۇيغۇرچە‎
uk	Українська
ur	اردو
uz	Ўзбек
ve	Tshivenḓa
vi	Tiếng Việt
vo	Volapük
wa	walon
wo	Wollof
xh	isiXhosa
yi	ייִדיש
yo	Yorùbá
za	Saɯ cueŋƅ
zh	中文
zu	isiZulu
]=]

local LABELS = {}
local CASE_FOLDED_LABELS = {}
local UI_FONT_FALLBACK_LABELS = {
    all = "All",
    my = "Burmese",
    te = "Telugu",
    ti = "Tigrinya",
}

for line in RAW_LABELS:gmatch("[^\n]+") do
    local code, label = line:match("^([^\t]+)\t(.+)$")
    if code and label then
        LABELS[code] = label
        CASE_FOLDED_LABELS[code:lower()] = label
    end
end

local function resolveLabel(code)
    if code == nil then
        return nil
    end
    code = tostring(code)
    if code == "" then
        return nil
    end

    local normalized_code = code:gsub("_", "-")
    local base_code = normalized_code:match("^([^%-]+)")
    return UI_FONT_FALLBACK_LABELS[code]
        or UI_FONT_FALLBACK_LABELS[code:lower()]
        or UI_FONT_FALLBACK_LABELS[normalized_code]
        or UI_FONT_FALLBACK_LABELS[normalized_code:lower()]
        or (base_code and UI_FONT_FALLBACK_LABELS[base_code:lower()])
        or LABELS[code]
        or CASE_FOLDED_LABELS[code:lower()]
        or LABELS[normalized_code]
        or CASE_FOLDED_LABELS[normalized_code:lower()]
        or (base_code and CASE_FOLDED_LABELS[base_code:lower()])
end

function SourceLanguages.formatLabel(code)
    return resolveLabel(code) or tostring(code or "")
end

function SourceLanguages.compare(left, right)
    return SourceLanguages.formatLabel(left):lower() < SourceLanguages.formatLabel(right):lower()
end

return SourceLanguages
