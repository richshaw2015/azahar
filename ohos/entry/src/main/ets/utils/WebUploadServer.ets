import { socket } from '@kit.NetworkKit';
import { wifiManager } from '@kit.ConnectivityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { FileManagerHelper } from './FileManagerHelper';
import { DeviceProfile } from './DeviceProfile';

enum UploadPhase {
  HttpHeader,
  PartHeader,
  FileBody,
  Done
}

interface ConnectionContext {
  headerChunks: Uint8Array[];
  partHeaderChunks: Uint8Array[];
  phase: UploadPhase;
  contentLength: number;
  boundary: string;
  method: string;
  path: string;
  fileFd: number;
  filename: string;
  fileWritten: number;
  fileSize: number;
  tailLength: number;
  writeQueue: Promise<void>;
}

export enum ServerStatus {
  STOPPED = 'stopped',
  STARTING = 'starting',
  RUNNING = 'running',
  STOPPING = 'stopping'
}

export interface ServerInfo {
  status: ServerStatus;
  port: number;
  localIp: string;
  uploadPath: string;
}

export interface UploadProgress {
  filename: string;
  uploadedBytes: number;
  totalBytes: number;
}

export class WebUploadServer {
  private static instance: WebUploadServer | null = null;
  private tcpServer: socket.TCPSocketServer | null = null;
  private status: ServerStatus = ServerStatus.STOPPED;
  private port: number = 8080;
  private localIp: string = '';
  private uploadPath: string = '';
  private connectionId: number = 0;
  private contexts: Map<number, ConnectionContext> = new Map();
  private uploadProgress: Map<number, UploadProgress> = new Map();
  private statusListeners: ((info: ServerInfo) => void)[] = [];
  private uploadCompleteListeners: ((filename: string, size: number) => void)[] = [];

  static getInstance(): WebUploadServer {
    if (!WebUploadServer.instance) {
      WebUploadServer.instance = new WebUploadServer();
    }
    return WebUploadServer.instance;
  }

  async start(uploadPath: string, port: number = 8080): Promise<boolean> {
    if (this.status === ServerStatus.RUNNING) {
      return true;
    }
    if (this.status === ServerStatus.STARTING) {
      return false;
    }

    await this.stop();
    this.status = ServerStatus.STARTING;
    this.uploadPath = uploadPath;
    this.localIp = this.getLocalIpAddress();
    this.notifyStatusChange();

    // 应用分身与主应用同机并存时基础端口错开，减少端口探测轮次
    const basePort = port + DeviceProfile.getAppCloneIndex();
    const portsToTry: number[] = [basePort, basePort + 1, basePort + 2, basePort + 10, basePort + 100];
    for (const tryPort of portsToTry) {
      try {
        this.tcpServer = socket.constructTCPSocketServerInstance();
        await this.tcpServer.listen({
          address: '0.0.0.0',
          port: tryPort,
          family: 1
        });
        this.port = tryPort;
        this.tcpServer.on('connect', (connection: socket.TCPSocketConnection) => {
          this.handleConnection(connection);
        });
        this.status = ServerStatus.RUNNING;
        this.notifyStatusChange();
        return true;
      } catch (error) {
        console.warn(`WebUploadServer: listen on port ${tryPort} failed: ${(error as Error).message}`);
        if (this.tcpServer) {
          try {
            this.tcpServer.off('connect');
          } catch (_ignored) {
            // 端口监听失败回滚，继续尝试下一端口
          }
          this.tcpServer = null;
        }
      }
    }

    this.status = ServerStatus.STOPPED;
    this.notifyStatusChange();
    return false;
  }

  async stop(): Promise<void> {
    if (this.status !== ServerStatus.RUNNING && this.status !== ServerStatus.STARTING) {
      return;
    }
    this.status = ServerStatus.STOPPING;
    this.notifyStatusChange();
    try {
      if (this.tcpServer) {
        this.tcpServer.off('connect');
        await this.tcpServer.close();
      }
    } catch (_error) {
      // 关闭 socket 幂等，失败继续清理
    } finally {
      this.contexts.forEach((ctx: ConnectionContext) => {
        if (ctx.fileFd >= 0) {
          try {
            fileIo.closeSync(ctx.fileFd);
          } catch (_ignored) {
            // 关闭句柄/连接幂等，失败可忽略
          }
        }
      });
      this.contexts.clear();
      this.uploadProgress.clear();
      this.tcpServer = null;
      this.status = ServerStatus.STOPPED;
      this.notifyStatusChange();
    }
  }

  getServerInfo(): ServerInfo {
    return {
      status: this.status,
      port: this.port,
      localIp: this.localIp,
      uploadPath: this.uploadPath
    };
  }

  getUploadProgress(): UploadProgress[] {
    return Array.from(this.uploadProgress.values());
  }

  addStatusListener(listener: (info: ServerInfo) => void): void {
    this.statusListeners.push(listener);
  }

  removeStatusListener(listener: (info: ServerInfo) => void): void {
    const index = this.statusListeners.indexOf(listener);
    if (index >= 0) {
      this.statusListeners.splice(index, 1);
    }
  }

  addUploadCompleteListener(listener: (filename: string, size: number) => void): void {
    this.uploadCompleteListeners.push(listener);
  }

  removeUploadCompleteListener(listener: (filename: string, size: number) => void): void {
    const index = this.uploadCompleteListeners.indexOf(listener);
    if (index >= 0) {
      this.uploadCompleteListeners.splice(index, 1);
    }
  }

  private notifyStatusChange(): void {
    const info = this.getServerInfo();
    this.statusListeners.forEach((listener: (info: ServerInfo) => void) => {
      listener(info);
    });
  }

  private notifyUploadComplete(filename: string, size: number): void {
    this.uploadCompleteListeners.forEach((listener: (filename: string, size: number) => void) => {
      listener(filename, size);
    });
  }

  private getLocalIpAddress(): string {
    try {
      const ipInfo = wifiManager.getIpInfo();
      if (ipInfo && ipInfo.ipAddress) {
        const ip = ipInfo.ipAddress;
        return `${(ip >> 24) & 0xff}.${(ip >> 16) & 0xff}.${(ip >> 8) & 0xff}.${ip & 0xff}`;
      }
    } catch (error) {
      console.warn(`WebUploadServer: getIpInfo failed: ${(error as Error).message}`);
    }
    return '0.0.0.0';
  }

  private handleConnection(connection: socket.TCPSocketConnection): void {
    const connId = ++this.connectionId;
    const context: ConnectionContext = {
      headerChunks: [],
      partHeaderChunks: [],
      phase: UploadPhase.HttpHeader,
      contentLength: 0,
      boundary: '',
      method: '',
      path: '',
      fileFd: -1,
      filename: '',
      fileWritten: 0,
      fileSize: 0,
      tailLength: 0,
      writeQueue: Promise.resolve()
    };
    this.contexts.set(connId, context);

    connection.on('message', (value: socket.SocketMessageInfo) => {
      const ctx = this.contexts.get(connId);
      if (!ctx || ctx.phase === UploadPhase.Done) {
        return;
      }
      this.processStreamData(connection, connId, ctx, new Uint8Array(value.message));
    });

    connection.on('close', () => {
      this.cleanupConnection(connId);
    });
  }

  private processStreamData(connection: socket.TCPSocketConnection, connId: number, ctx: ConnectionContext, data: Uint8Array): void {
    if (ctx.phase === UploadPhase.HttpHeader) {
      this.processHttpHeader(connection, connId, ctx, data);
    } else if (ctx.phase === UploadPhase.PartHeader) {
      this.processPartHeader(connection, connId, ctx, data);
    } else if (ctx.phase === UploadPhase.FileBody) {
      this.processFileBody(connection, connId, ctx, data);
    }
  }

  private processHttpHeader(connection: socket.TCPSocketConnection, connId: number, ctx: ConnectionContext, data: Uint8Array): void {
    ctx.headerChunks.push(data);
    const buffer = this.mergeChunks(ctx.headerChunks);
    const headerEnd = this.findHeaderEnd(buffer);
    if (headerEnd < 0) {
      return;
    }

    const headerText = this.uint8ArrayToString(buffer.slice(0, headerEnd));
    const lines = headerText.split('\r\n');
    const requestParts = lines[0].split(' ');
    if (requestParts.length < 2) {
      this.sendErrorResponse(connection, 400, 'Bad Request');
      this.cleanupConnection(connId);
      return;
    }
    ctx.method = requestParts[0];
    ctx.path = requestParts[1];

    for (const line of lines) {
      const lower = line.toLowerCase();
      if (lower.startsWith('content-length:')) {
        ctx.contentLength = Number(line.substring(15).trim());
      } else if (lower.startsWith('content-type:')) {
        const boundaryMatch = line.match(/boundary=([^\s;]+)/i);
        if (boundaryMatch) {
          ctx.boundary = boundaryMatch[1];
        }
      }
    }
    ctx.headerChunks = [];

    if (ctx.method === 'GET') {
      if (ctx.path === '/' || ctx.path === '/upload') {
        this.sendUploadPage(connection);
      } else {
        this.sendErrorResponse(connection, 404, 'Not Found');
      }
      this.cleanupConnection(connId);
      return;
    }

    if (ctx.method !== 'POST' || ctx.path !== '/upload_file' || !ctx.boundary || ctx.contentLength <= 0) {
      this.sendErrorResponse(connection, 405, 'Method Not Allowed');
      this.cleanupConnection(connId);
      return;
    }

    ctx.tailLength = 2 + 2 + ctx.boundary.length + 2 + 2;
    ctx.phase = UploadPhase.PartHeader;
    const bodyStart = headerEnd + 4;
    if (bodyStart < buffer.length) {
      this.processStreamData(connection, connId, ctx, buffer.slice(bodyStart));
    }
  }

  private processPartHeader(connection: socket.TCPSocketConnection, connId: number, ctx: ConnectionContext, data: Uint8Array): void {
    ctx.partHeaderChunks.push(data);
    const buffer = this.mergeChunks(ctx.partHeaderChunks);
    const boundaryLine = this.stringToUint8Array(`--${ctx.boundary}`);
    const boundaryIndex = this.findSequence(buffer, boundaryLine, 0);
    if (boundaryIndex < 0) {
      return;
    }

    let offset = boundaryIndex + boundaryLine.length;
    if (offset + 2 > buffer.length) {
      return;
    }
    if (buffer[offset] === 0x2d && buffer[offset + 1] === 0x2d) {
      ctx.phase = UploadPhase.Done;
      this.sendUploadResponse(connection, connId);
      return;
    }
    if (buffer[offset] === 0x0d && buffer[offset + 1] === 0x0a) {
      offset += 2;
    }

    const partHeaderEnd = this.findHeaderEnd(buffer.slice(offset));
    if (partHeaderEnd < 0) {
      return;
    }

    const partHeader = this.uint8ArrayToString(buffer.slice(offset, offset + partHeaderEnd));
    const filenameMatch = partHeader.match(/filename="([^"]+)"/);
    if (!filenameMatch) {
      this.sendErrorResponse(connection, 400, 'Missing File');
      this.cleanupConnection(connId);
      return;
    }

    ctx.filename = filenameMatch[1];
    const partHeaderSize = offset + partHeaderEnd + 4;
    ctx.fileSize = ctx.contentLength - partHeaderSize - ctx.tailLength;
    if (ctx.fileSize < 0) {
      this.sendErrorResponse(connection, 400, 'Invalid Upload');
      this.cleanupConnection(connId);
      return;
    }

    ctx.partHeaderChunks = [];
    ctx.phase = UploadPhase.FileBody;
    ctx.writeQueue = ctx.writeQueue.then(async () => {
      await this.openFileForStreaming(ctx);
    }).catch((_error: Error) => {
      this.sendErrorResponse(connection, 500, 'Open File Failed');
      this.cleanupConnection(connId);
    });

    const fileStart = partHeaderSize;
    if (fileStart < buffer.length) {
      this.processFileBody(connection, connId, ctx, buffer.slice(fileStart));
    }
  }

  private processFileBody(connection: socket.TCPSocketConnection, connId: number, ctx: ConnectionContext, data: Uint8Array): void {
    const remaining = ctx.fileSize - ctx.fileWritten;
    if (remaining <= 0) {
      return;
    }
    const bytesToWrite = Math.min(data.length, remaining);
    const writeData = bytesToWrite < data.length ? data.slice(0, bytesToWrite) : data;
    ctx.fileWritten += bytesToWrite;
    const finished = ctx.fileWritten >= ctx.fileSize;

    this.uploadProgress.set(connId, {
      filename: ctx.filename,
      uploadedBytes: ctx.fileWritten,
      totalBytes: ctx.fileSize
    });

    ctx.writeQueue = ctx.writeQueue.then(async () => {
      if (ctx.fileFd < 0) {
        return;
      }
      await fileIo.write(ctx.fileFd, writeData.buffer);
      if (finished) {
        this.finishCurrentFile(connection, connId, ctx);
      }
    }).catch((_error: Error) => {
      this.sendErrorResponse(connection, 500, 'Write Failed');
      this.cleanupConnection(connId);
    });
  }

  private finishCurrentFile(connection: socket.TCPSocketConnection, connId: number, ctx: ConnectionContext): void {
    if (ctx.phase === UploadPhase.Done) {
      return;
    }
    ctx.phase = UploadPhase.Done;
    if (ctx.fileFd >= 0) {
      try {
        fileIo.closeSync(ctx.fileFd);
      } catch (_ignored) {
        // 关闭句柄/连接幂等，失败可忽略
      }
      ctx.fileFd = -1;
    }
    this.notifyUploadComplete(ctx.filename, ctx.fileWritten);
    this.sendUploadResponse(connection, connId);
  }

  private async openFileForStreaming(ctx: ConnectionContext): Promise<void> {
    let safePath = ctx.filename;
    while (safePath.startsWith('/') || safePath.startsWith('\\')) {
      safePath = safePath.substring(1);
    }
    safePath = safePath.replace(/\.\./g, '_').replace(/\\/g, '/');
    ctx.filename = safePath;

    const filePath = `${this.uploadPath}/${safePath}`;
    const slash = filePath.lastIndexOf('/');
    if (slash > 0) {
      try {
        await fileIo.mkdir(filePath.substring(0, slash), true);
      } catch (error) {
        console.warn(`WebUploadServer: mkdir for upload failed: ${(error as Error).message}`);
      }
    }
    const file = await fileIo.open(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    ctx.fileFd = file.fd;
  }

  private sendUploadResponse(connection: socket.TCPSocketConnection, connId: number): void {
    const body = this.stringToArrayBuffer('OK');
    const headers = `HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ${body.byteLength}\r\nConnection: close\r\n\r\n`;
    this.sendResponseWithBody(connection, headers, body);
    this.cleanupConnection(connId);
  }

  private sendUploadPage(connection: socket.TCPSocketConnection): void {
    const body = this.stringToArrayBuffer(this.getUploadPageHtml());
    const headers = `HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${body.byteLength}\r\nConnection: close\r\n\r\n`;
    this.sendResponseWithBody(connection, headers, body);
  }

  private sendErrorResponse(connection: socket.TCPSocketConnection, code: number, message: string): void {
    const body = this.stringToArrayBuffer(`<html><body><h1>${code} ${message}</h1></body></html>`);
    const headers = `HTTP/1.1 ${code} ${message}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${body.byteLength}\r\nConnection: close\r\n\r\n`;
    this.sendResponseWithBody(connection, headers, body);
  }

  private sendResponseWithBody(connection: socket.TCPSocketConnection, headers: string, body: ArrayBuffer): void {
    connection.send({ data: headers }).then(() => {
      return connection.send({ data: body });
    }).then(() => {
      connection.close();
    }).catch((_error: Error) => {
      try {
        connection.close();
      } catch (_ignored) {
        // 关闭句柄/连接幂等，失败可忽略
      }
    });
  }

  private cleanupConnection(connId: number): void {
    const ctx = this.contexts.get(connId);
    if (ctx && ctx.fileFd >= 0) {
      try {
        fileIo.closeSync(ctx.fileFd);
      } catch (_ignored) {
        // 关闭句柄/连接幂等，失败可忽略
      }
    }
    // 上传完成的进度项多留一会儿再删，面板才能看到进度走到 100%
    if (this.uploadProgress.has(connId)) {
      setTimeout(() => {
        this.uploadProgress.delete(connId);
      }, 1500);
    }
    this.contexts.delete(connId);
  }

  private mergeChunks(chunks: Uint8Array[]): Uint8Array {
    if (chunks.length === 1) {
      return chunks[0];
    }
    const total = chunks.reduce((sum: number, chunk: Uint8Array) => sum + chunk.length, 0);
    const result = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      result.set(chunk, offset);
      offset += chunk.length;
    }
    return result;
  }

  private findHeaderEnd(data: Uint8Array): number {
    return this.findSequence(data, new Uint8Array([0x0d, 0x0a, 0x0d, 0x0a]), 0);
  }

  private findSequence(data: Uint8Array, sequence: Uint8Array, startOffset: number): number {
    for (let i = startOffset; i <= data.length - sequence.length; i++) {
      let found = true;
      for (let j = 0; j < sequence.length; j++) {
        if (data[i + j] !== sequence[j]) {
          found = false;
          break;
        }
      }
      if (found) {
        return i;
      }
    }
    return -1;
  }

  private uint8ArrayToString(data: Uint8Array): string {
    return new util.TextDecoder('utf-8').decodeToString(data);
  }

  private stringToArrayBuffer(value: string): ArrayBuffer {
    return new util.TextEncoder().encodeInto(value).buffer;
  }

  private stringToUint8Array(value: string): Uint8Array {
    return new util.TextEncoder().encodeInto(value);
  }

  private getUploadPageHtml(): string {
    const displayPath = FileManagerHelper.getDisplayPath(this.uploadPath);
    const deviceName = deviceInfo.marketName || deviceInfo.productModel || 'Azahar';
    return `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Azahar Web 上传</title>
<style>
body{font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#f4f7fb;color:#172033;max-width:720px;margin:0 auto;padding:28px}
h1{font-size:24px;margin:0 0 8px}
p{color:#526070}
.path{font-family:monospace;background:#e8edf5;padding:3px 6px;border-radius:6px}
.panel{background:#fff;border:1px solid #d8e0ec;border-radius:10px;padding:18px;margin-top:18px}
button,.button{display:inline-block;border:0;border-radius:8px;background:#2f74d0;color:white;padding:10px 14px;font-size:15px;margin-right:8px;cursor:pointer}
button:disabled{background:#aeb8c6;cursor:not-allowed}
input[type=file]{display:none}
#drop{border:2px dashed #b6c4d6;border-radius:10px;padding:34px 14px;text-align:center;color:#5f6d7f;margin-top:16px}
#drop.over{border-color:#2f74d0;background:#eef6ff}
#list{font-size:14px;margin-top:12px;word-break:break-all}
progress{width:100%;height:18px;margin-top:14px;display:none}
#error{color:#c62828;margin-top:10px}
#status{color:#2f6f3e;margin-top:10px}
</style></head><body>
<h1>上传文件到 ${deviceName}</h1>
<p>目标目录：<span class="path">${displayPath}</span></p>
<div class="panel">
<label class="button">选择文件<input id="file" type="file" multiple></label>
<label class="button">选择文件夹<input id="folder" type="file" webkitdirectory multiple></label>
<button id="reset" style="display:none">重置</button>
<div id="drop">拖放 .3ds/.cia/.cci 等文件到这里</div>
<div id="list"></div>
<button id="upload" disabled style="margin-top:14px">开始上传</button>
<progress id="progress" value="0" max="100"></progress>
<div id="status"></div>
<div id="error"></div>
</div>
<script>
(function(){
var file=document.getElementById("file"),folder=document.getElementById("folder"),drop=document.getElementById("drop");
var upload=document.getElementById("upload"),reset=document.getElementById("reset"),list=document.getElementById("list");
var progress=document.getElementById("progress"),status=document.getElementById("status"),error=document.getElementById("error");
var dropped=[],files=[];
function fmt(bytes){if(!bytes)return"0 B";var u=["B","KB","MB","GB"],i=Math.min(u.length-1,Math.floor(Math.log(bytes)/Math.log(1024)));return (bytes/Math.pow(1024,i)).toFixed(i?1:0)+" "+u[i];}
function refresh(){files=[].concat(Array.from(file.files),Array.from(folder.files),dropped);upload.disabled=files.length===0;reset.style.display=files.length?"inline-block":"none";var total=files.reduce(function(s,f){return s+(f.size||0)},0);list.textContent=files.length?("已选择 "+files.length+" 个文件，共 "+fmt(total)):"";}
file.onchange=refresh;folder.onchange=refresh;
reset.onclick=function(){file.value="";folder.value="";dropped=[];files=[];status.textContent="";error.textContent="";refresh();};
drop.ondragover=function(e){e.preventDefault();drop.classList.add("over");};
drop.ondragleave=function(e){e.preventDefault();drop.classList.remove("over");};
drop.ondrop=function(e){e.preventDefault();drop.classList.remove("over");dropped=dropped.concat(Array.from(e.dataTransfer.files).filter(function(f){return f.size>0;}));refresh();};
document.addEventListener("dragover",function(e){e.preventDefault();});
document.addEventListener("drop",function(e){e.preventDefault();});
upload.onclick=function(){
if(!files.length)return;upload.disabled=true;error.textContent="";status.textContent="";progress.style.display="block";progress.value=0;
var total=files.reduce(function(s,f){return s+(f.size||0)},0),done=0,index=0;
function sendNext(){if(index>=files.length){status.textContent="上传完成";progress.style.display="none";file.value="";folder.value="";dropped=[];refresh();return;}
var f=files[index],xhr=new XMLHttpRequest(),fd=new FormData();fd.append("file",f,f.webkitRelativePath||f.name);xhr.open("POST","/upload_file");
xhr.upload.onprogress=function(e){if(e.lengthComputable){progress.value=total?((done+e.loaded)/total)*100:100;status.textContent="正在上传 "+(f.webkitRelativePath||f.name);}};
xhr.onload=function(){if(xhr.status>=200&&xhr.status<300){done+=f.size||0;index++;sendNext();}else{error.textContent="上传失败，状态码 "+xhr.status;upload.disabled=false;}};
xhr.onerror=function(){error.textContent="连接失败";upload.disabled=false;};
xhr.send(fd);}
sendNext();
};
})();
<\/script></body></html>`;
  }
}
