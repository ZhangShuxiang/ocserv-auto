import random

# pyinstaller -F e:/Python/py/7/抽卡模拟.py

kc_5u = ["🔶希格雯"]
kc_5x = ["🔷提纳里", "🔷莫娜", "🔷迪卢克", "🔷迪希雅", "🔷刻晴", "🔷七七", "🔷琴"]
kc_4u = ["🔸嘉明", "🔸罗莎莉亚", "🔸诺艾尔"]
kc_4x = [
    "🔹夏沃蕾",
    "🔹夏洛蒂",
    "🔹菲米尼",
    "🔹琳妮特",
    "🔹卡维",
    "🔹米卡",
    "🔹瑶瑶",
    "🔹珐露珊",
    "🔹莱依拉",
    "🔹坎蒂丝",
    "🔹多莉",
    "🔹柯莱",
    "🔹久岐忍",
    "🔹云堇",
    "🔹绮良良",
    "🔹鹿野院平藏",
    "🔹九条裟罗",
    "🔹五郎",
    "🔹早柚",
    "🔹托马",
    "🔹烟绯",
    "🔹辛焱",
    "🔹砂糖",
    "🔹迪奥娜",
    "🔹重云",
    "🔹班尼特",
    "🔹菲谢尔",
    "🔹凝光",
    "🔹行秋",
    "🔹北斗",
    "🔹香菱",
    "🔹雷泽",
    "🔹芭芭拉",
    "🔹匣里龙吟",
    "🔹祭礼剑",
    "🔹笛剑",
    "🔹西风剑",
    "🔹雨裁",
    "🔹祭礼大剑",
    "🔹钟剑",
    "🔹西风大剑",
    "🔹西风长枪",
    "🔹匣里灭辰",
    "🔹昭心",
    "🔹祭礼残章",
    "🔹流浪乐章",
    "🔹西风秘典",
    "🔹弓藏",
    "🔹祭礼弓",
    "🔹绝弦",
    "🔹西风猎弓",
]
kc_3x = [
    "飞天御剑",
    "黎明神剑",
    "冷刃",
    "以理服人",
    "沐浴龙血的剑",
    "铁影阔剑",
    "黑缨枪",
    "翡玉法球",
    "讨龙英杰谭",
    "魔导绪论",
    "弹弓",
    "神射手之誓",
    "鸦羽弓",
]
a, b, c, d = len(kc_5x), len(kc_5u), len(kc_4x), len(kc_4u)
list1, list2, aa, bb, cc = [], [], [1, 0], [1, 0], [0, 0, 0]


def choukamoni():
    # ====================五星====================
    sui_a = random.randint(0, 1000)
    num_a = 6 + (0 if (aa[1] - 73) < 0 else (aa[1] - 73)) * 60
    qz_5x = [int(a / b)] * b + [aa[0]] * a
    # ---------------
    if sui_a < num_a:
        ck_5x = random.choices(kc_5u + kc_5x, qz_5x)[0]
        aa[0] = 1 if ck_5x in kc_5u else 0
        list1.append(ck_5x)
        aa[1] = 0
        cc[0] = cc[0] + 1
    else:
        aa[1] = aa[1] + 1
    # ====================四星====================
    sui_b = random.randint(0, 1000)
    num_b = 51 + (0 if (bb[1] - 8) < 0 else (bb[1] - 8)) * 510
    qz_4x = [int(c / d)] * d + [bb[0]] * c
    # ---------------
    if sui_b < num_b:
        ck_4x = random.choices(kc_4u + kc_4x, qz_4x)[0]
        bb[0] = 1 if ck_4x in kc_4u else 0
        list2.append(ck_4x)
        bb[1] = 0
        cc[1] = cc[1] + 1
    else:
        bb[1] = bb[1] + 1
    # ====================三星====================
    if aa[1] != 0:
        if len(list2) > 0:
            list1.append(list2.pop(0))
        else:
            ck_3x = random.choice(kc_3x)
            list1.append(ck_3x)


while True:
    cks = input("请输入抽卡次数(默认十连,输入q退出):") or "10"
    if cks.isdigit():
        for i in range(0, int(cks)):
            choukamoni()
        cc[2] = cc[2] + int(cks)
        # print(list1)
        print(
            "金卡次数",
            cc[0],
            "，平均每",
            (0 if cc[0] == 0 else cc[2] / cc[0]),
            "抽出金",
            "\n紫卡次数",
            cc[1],
            "，平均每",
            (0 if cc[1] == 0 else cc[2] / cc[1]),
            "抽出紫",
        )
        list1.clear()
    elif cks == "q":
        break
