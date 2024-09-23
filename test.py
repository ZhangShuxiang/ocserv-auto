import random
import tkinter

list1 = list(range(48, 57))
list2 = list(range(65, 90))
list3 = list(range(97, 122))
list4 = list(range(33, 126))


def button_1():
    listx = []
    list9 = []
    if CheckVar1.get() == 1:
        list9.extend(list1)
    if CheckVar2.get() == 1:
        list9.extend(list2)
    if CheckVar3.get() == 1:
        list9.extend(list3)
    if CheckVar4.get() == 1:
        list9.clear()
        list9.extend(list4)
    if len(list9) == 0:
        list9.extend(list4)
    print(list9)
    for i in range(20):
        x = random.choice(list9)
        listx.append(chr(x))
    print("".join(listx))


# 创建主窗口
root = tkinter.Tk()
root.geometry("300x200")
root.title("Tkinter示例")

# 创建标签
CheckVar1 = tkinter.IntVar()
CheckVar2 = tkinter.IntVar()
CheckVar3 = tkinter.IntVar()
CheckVar4 = tkinter.IntVar()
C1 = tkinter.Checkbutton(
    root, text="数字", variable=CheckVar1, onvalue=1, offvalue=0, height=1, width=8
)
C2 = tkinter.Checkbutton(
    root, text="大写字母", variable=CheckVar2, onvalue=1, offvalue=0, height=1, width=8
)
C3 = tkinter.Checkbutton(
    root, text="小写字母", variable=CheckVar3, onvalue=1, offvalue=0, height=1, width=8
)
C4 = tkinter.Checkbutton(
    root, text="全部字符", variable=CheckVar4, onvalue=1, offvalue=0, height=1, width=8
)
C1.pack()
C2.pack()
C3.pack()
C4.pack()

txt = tkinter.Entry(root, textvariable=button_1)


# 创建按钮
button = tkinter.Button(
    root,
    text="点击我",
    command=button_1,
    width=10,
    height=2,
)
button.place(x=10, y=50)
button.pack()

# 运行主循环
root.mainloop()
