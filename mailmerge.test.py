import os
import time
import xlwings
from mailmerge import MailMerge

docx = r'E:\Download\py\1\demowd.docx'
xlsx = r'E:\Download\py\1\demoxl.xlsx'

filepath = os.path.dirname(docx)
time = time.strftime("%Y%m%d")
filepath2 = os.mkdir('证书'+time)
app = xlwings.App(visible=False,add_book=False)
workbook = app.books.open(xlsx)
worksheet = xlwings.sheets['证书']
worksheet.range('H:H').api.NumberFormat = "@"
nrow = worksheet.used_range.last_cell.row

for key in range(1,nrow):
    with MailMerge(docx) as doc:
        doc.merge(
            姓名 = str(worksheet[key, 0].value),
            性别 = str(worksheet[key, 1].value),
            出生日期 = str(worksheet[key, 2].value),
            公司 = str(worksheet[key, 3].value),
            工作专业 = str(worksheet[key, 4].value),
            原职务 = str(worksheet[key, 5].value),
            现职务 = str(worksheet[key, 6].value),
            证书编号 = str(worksheet[key, 7].value),
            评审时间 = str(worksheet[key, 8].value),
            公布时间 = str(worksheet[key, 9].value),
            公布文号 = str(worksheet[key, 10].value),
            )
    
        output = filepath + r'\证书-{}.docx'.format(str(worksheet[key, 0].value))
        doc.write(output)

app.quit()
