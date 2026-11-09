// ==UserScript==
// @name         AIVideo ChatGPT Bridge - Operator Approved
// @namespace    https://github.com/bunbolamlac77/VideoAI
// @version      2.0.0
// @description  Send intentionally copied code to a secure local VideoAI worker; no ChatGPT output scraping
// @match        https://chatgpt.com/*
// @grant        GM_xmlhttpRequest
// @grant        GM_getValue
// @grant        GM_setValue
// @connect      127.0.0.1
// @run-at       document-idle
// @noframes
// ==/UserScript==

(() => {
  'use strict';
  if (window.top !== window.self) return;
  const ENDPOINT = 'http://127.0.0.1:8765';
  const ID = 'aivideo-bridge-v2';
  if (document.getElementById(ID)) return;

  const host = document.createElement('aside');
  host.id = ID;
  host.style.cssText = `position:fixed;right:18px;bottom:18px;z-index:2147483646;
    width:380px;max-width:calc(100vw - 36px);background:#151822;color:#f5f7fa;
    font:12px/1.45 system-ui,sans-serif;padding:13px;box-sizing:border-box;
    border:1px solid #465064;border-radius:12px;box-shadow:0 14px 40px #0009;`;
  const shadow = host.attachShadow({mode:'open'});
  shadow.innerHTML = `<style>
    *{box-sizing:border-box} .head{display:flex;justify-content:space-between;align-items:center}
    b{font-size:14px} input,textarea{width:100%;background:#242a39;color:#fafafa;
    border:1px solid #586175;border-radius:7px;padding:8px;font:12px ui-monospace,monospace}
    textarea{resize:vertical;min-height:105px} button{cursor:pointer;border:0;border-radius:7px;
    padding:8px;background:#2d7df4;color:white;font-weight:650}
    button.alt{background:#354053} button:disabled{opacity:.5;cursor:wait}
    .actions{display:flex;gap:7px;margin:7px 0} .actions>*{flex:1}
    .sub{color:#aab8ce;margin:7px 0} #status{white-space:pre-wrap;overflow-wrap:anywhere}
    details{margin-top:8px} summary{cursor:pointer} #details{max-height:125px;overflow:auto}
  </style>
  <div class="head"><b>AIVideo Bridge v2</b><button id="collapse" class="alt">_</button></div>
  <div id="panel">
    <div class="sub">Chỉ chạy ở máy bạn. Không tự đọc câu trả lời ChatGPT.</div>
    <input id="token" type="password" placeholder="Dán bridge token tại đây">
    <div class="actions"><button id="save" class="alt">Lưu token</button>
      <button id="refresh" class="alt">Kiểm tra kết nối</button></div>
    <textarea id="bundle" spellcheck="false" placeholder="Dán câu trả lời có khối FILE: path chứa code"></textarea>
    <div class="actions"><button id="submit">Duyệt & áp dụng code</button>
      <button id="copy" class="alt">Copy báo cáo test</button></div>
    <div id="status" class="sub" aria-live="polite">Chưa kết nối.</div>
    <details><summary>File trong vòng gần nhất</summary><pre id="details"></pre></details>
  </div>`;
  document.body.append(host);

  const $ = (id) => shadow.getElementById(id);
  const status = (message, color='#aab8ce') => { $('status').textContent=message; $('status').style.color=color; };
  const tokenField = $('token');
  tokenField.value = GM_getValue('bridgeToken', '');
  let lastReport = '';
  let checking = false;

  const api = (method, path, data) => new Promise((resolve,reject) => {
    const token=tokenField.value.trim();
    if (!token) return reject(new Error('Chưa nhập token'));
    GM_xmlhttpRequest({
      method, url:ENDPOINT+path,
      headers:{'X-Bridge-Token':token, ...(data?{'Content-Type':'application/json'}:{})},
      data:data?JSON.stringify(data):undefined, timeout:8000,
      onload: res => {
        let obj;
        try { obj=JSON.parse(res.responseText); } catch { return reject(new Error('Bridge trả dữ liệu không hợp lệ')); }
        if (res.status < 200 || res.status >= 300) return reject(new Error(obj.error || `HTTP ${res.status}`));
        resolve(obj);
      },
      onerror:()=>reject(new Error('Không kết nối được bridge tại 127.0.0.1:8765')),
      ontimeout:()=>reject(new Error('Bridge timeout'))
    });
  });

  $('save').addEventListener('click',()=>{
    GM_setValue('bridgeToken', tokenField.value.trim());
    status('Token đã lưu trong Tampermonkey.');
  });
  $('refresh').addEventListener('click', refresh);
  $('submit').addEventListener('click', async ()=>{
    const content=$('bundle').value.trim();
    if(!content.includes('```FILE:')) return status('Thiếu khối ```FILE: relative/path', '#fca5a5');
    $('submit').disabled=true;
    status('Đang gửi code đã duyệt...', '#fbbf24');
    try {
      const r=await api('POST','/api/submit',{content});
      status(`Đã nhận job ${r.id}: ${r.state}. ${r.files.length} file.`, '#86efac');
      $('bundle').value='';
      await refresh();
    } catch(e) { status(e.message, '#fca5a5'); }
    finally {$('submit').disabled=false;}
  });
  $('copy').addEventListener('click', async ()=>{
    if(!lastReport) return status('Chưa có báo cáo test.', '#fbbf24');
    try { await navigator.clipboard.writeText(lastReport); status('Đã copy báo cáo, dán vào ChatGPT để review.', '#86efac'); }
    catch { status('Trình duyệt chặn clipboard. Hãy dùng nút Copy theo quyền trình duyệt.', '#fca5a5'); }
  });
  $('collapse').addEventListener('click',()=>{
    const panel=$('panel');
    panel.hidden=!panel.hidden;
    $('collapse').textContent=panel.hidden?'+':'_';
  });
  async function refresh() {
    if(checking || !tokenField.value.trim()) return;
    checking=true;
    try {
      const r=await api('GET','/api/status');
      const job=r.latest;
      if(!job) { status('Đã kết nối; chưa có công việc.', '#86efac'); }
      else {
        const color={done:'#86efac',failed:'#fca5a5',interrupted:'#fca5a5',running:'#93c5fd',queued:'#fbbf24'}[job.state];
        status(`${job.state.toUpperCase()} | ${job.id}\n${job.updated}`,color);
        $('details').textContent=job.files.join('\n');
        lastReport=job.result?`BÁO CÁO WORKER VIDEOAI\n${job.result}`:'';
      }
    } catch(e) { status(e.message, '#fca5a5'); }
    finally {checking=false;}
  }
  setInterval(refresh, 4000);
  refresh();
})();
