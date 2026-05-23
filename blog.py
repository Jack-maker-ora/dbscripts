# app.py
from flask import Flask, render_template

app = Flask(__name__)

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/data/<page>')
def data(page):
    # 根据菜单项返回不同数据
    return f"这是 {page} 页面的数据"


if __name__ == '__main__':
    app.run()