"""Manual GUI check: requires PySide6, a running server, and desktop focus.

Creates a temporary text editor and sends known text through the local server.
The production keyboard flow uses Lua/FFI; Python is only this test driver.
"""
import json, os, sys, time, threading, urllib.request as url
os.environ['QT_QPA_PLATFORM']='wayland'
from PySide6.QtWidgets import QApplication, QTextEdit
from PySide6.QtCore import QTimer, QMimeData
app=QApplication([])
window=QTextEdit()
window.setWindowTitle('Unified Remote — validação temporária de teclado')
window.resize(740,220)
window.show();window.setFocus();window.activateWindow()
base='http://127.0.0.1:9510'
headers={}
results=[]
original=QMimeData()
clipboard=app.clipboard().mimeData()
if clipboard:
 for fmt in clipboard.formats():
  original.setData(fmt,clipboard.data(fmt))
common='Olá, ação! ç ã é @ # $ % & * ( ) [ ] { } / ? + ='
quoted='Aspas: \' " e barra \\; $ ( ) ` [ ] { }'
stages=[('Core.Input.Text: acentos e símbolos','Core.Input','Text',[common],common),
        ('Core.Keyboard.text: aspas e caracteres de shell','Core.Keyboard','text',[quoted],quoted),
        ('Core.Keyboard.character: Unicode','Core.Keyboard','character',[ord('ã')],'ã'),
        ('Core.Input.Text: sequência de 30 eventos','Core.Input','Text',list('abcdefghijklmnopqrstuvwxyz1234'),'abcdefghijklmnopqrstuvwxyz1234'),
        ('Core.Input.Text: 100 eventos mistos','Core.Input','Text',list('Abçãé0123!'*10),'Abçãé0123!'*10),
        ('Core.Input.Text: digitação sem auxiliar','Core.Input','Text',['Texto direto: ação 123'],'Texto direto: ação 123'),
        ('Core.Input.Text: teclas de edição','Core.Input','Text',['linha1\nabc\bD\tfim'],'linha1\nabD\tfim'),
        ('Core.Keyboard.character: emoji','Core.Keyboard','character',[ord('🙂')],'🙂'),
        ('Core.Keyboard.text: fallback Unicode','Core.Keyboard','text',['Unicode: € 🙂'],'Unicode: € 🙂')]
index=-1
started=0
expected=''
failed=False
def request(action,**kwargs):
 data={'Action':action,'Request':action,'Source':'keyboard-diagnostic',**kwargs}
 with url.urlopen(url.Request(base+'/client/request',json.dumps(data).encode(),headers),timeout=4) as response:
  return json.load(response)
def finish():
 if headers:
  url.urlopen(url.Request(base+'/client/disconnect',headers=headers),timeout=3).close()
 app.clipboard().setMimeData(original)
 print('Passed:',len(results),'of',len(stages),flush=True)
 app.quit()
def stage():
 global index, started, expected, failed
 index+=1
 if index==len(stages):
  finish();return
 if not window.isActiveWindow():
  print('Test window lost focus: aborting',flush=True);failed=True;finish();return
 name,target,action,values,expected=stages[index]
 window.clear()
 started=time.monotonic()
 def dispatch():
  for value in values:
   request(7,ID=target,Run={'Name':action,'Extras':{'Values':[{'Value':value}]}})
 threading.Thread(target=dispatch,daemon=True).start()
 poll()
def poll():
 global failed
 if window.toPlainText()==expected:
  elapsed=round(time.monotonic()-started,3)
  results.append(stages[index][0])
  print('PASS',stages[index][0],elapsed,'s',flush=True)
  QTimer.singleShot(150,stage)
 elif time.monotonic()-started>12:
  print('FAIL',stages[index][0],'received:',repr(window.toPlainText()),flush=True)
  failed=True;finish()
 else:
  QTimer.singleShot(25,poll)
def start():
 global failed
 if not window.isActiveWindow():
  print('Test window did not gain focus',flush=True);failed=True;finish();return
 connection=json.load(url.urlopen(base+'/client/connect',timeout=3))['id'].strip()
 headers.update({'UR-Connection-ID':connection,'Content-Type':'application/json'})
 request(0,Version=10,Platform='web',Password='keyboard-diagnostic')
 request(1,Capabilities={'Actions':True,'Sync':True,'Encryption2':True})
 stage()
QTimer.singleShot(1200,start)
QTimer.singleShot(55000,app.quit)
app.exec()
sys.exit(0 if len(results)==len(stages) and not failed else 1)
