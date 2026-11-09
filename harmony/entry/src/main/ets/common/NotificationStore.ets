import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Logger } from './Logger';
import { EventRecord, trimRecords } from './FilterLogic';

export { EventRecord } from './FilterLogic';

/**
 * 扩展进程（NotificationSubscriberExtAbility）与 UI 进程之间的共享记录（JSON Lines，context.filesDir 同一沙箱目录）。
 *
 * 1.1.0 起**只保存元数据**：应用名 / 包名、时间、处理结果、发往哪些电脑；不保存标题和正文。
 * 敏感内容（被敏感过滤拦下的、银行/支付类验证码）不记录。最多 200 条、256 KB，超过 7 天的自动删除；
 * 可以在设置里关闭记录（filesDir/records_off 标记文件，两个进程都能看到）或清空。
 */
const FILE_NAME = 'events_v2.jsonl';
/** 1.0.x 的记录文件（含通知标题和正文），升级时删除 */
const LEGACY_FILE = 'received_events.jsonl';
const OFF_MARKER = 'records_off';

function filePath(filesDir: string): string {
  return `${filesDir}/${FILE_NAME}`;
}

function utf8Len(s: string): number {
  return new util.TextEncoder().encodeInto(s).length;
}

/** 删除 1.0.x 留下的含正文的记录文件（两个进程启动时都会调用，幂等） */
export function deleteLegacyRecords(filesDir: string): void {
  try {
    const p = `${filesDir}/${LEGACY_FILE}`;
    if (fs.accessSync(p)) {
      fs.unlinkSync(p);
      Logger.info('legacy received_events.jsonl deleted');
    }
  } catch (e) {
    Logger.warn(`delete legacy records failed: ${JSON.stringify(e)}`);
  }
}

export function recordsEnabled(filesDir: string): boolean {
  try {
    return !fs.accessSync(`${filesDir}/${OFF_MARKER}`);
  } catch (e) {
    return true;
  }
}

export function setRecordsEnabled(filesDir: string, on: boolean): void {
  const marker = `${filesDir}/${OFF_MARKER}`;
  try {
    if (on) {
      if (fs.accessSync(marker)) {
        fs.unlinkSync(marker);
      }
    } else {
      const f = fs.openSync(marker, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
      fs.closeSync(f);
      clearRecords(filesDir);
    }
  } catch (e) {
    Logger.error(`setRecordsEnabled failed: ${JSON.stringify(e)}`);
  }
}

function readAll(filesDir: string): Array<EventRecord> {
  const path = filePath(filesDir);
  const result: Array<EventRecord> = [];
  if (!fs.accessSync(path)) {
    return result;
  }
  const buf = new ArrayBuffer(fs.statSync(path).size);
  const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
  fs.readSync(file.fd, buf);
  fs.closeSync(file);
  const content = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
  for (const raw of content.split('\n')) {
    const line = raw.trim();
    if (line.length === 0) {
      continue;
    }
    try {
      result.push(JSON.parse(line) as EventRecord);
    } catch (e) {
      Logger.warn('skip malformed record line');
    }
  }
  return result;
}

function writeAll(filesDir: string, list: Array<EventRecord>): void {
  const tmp = `${filePath(filesDir)}.tmp`;
  const file = fs.openSync(tmp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  fs.writeSync(file.fd, list.map((r: EventRecord) => JSON.stringify(r)).join('\n') + (list.length > 0 ? '\n' : ''));
  fs.closeSync(file);
  fs.renameSync(tmp, filePath(filesDir));
}

export function appendRecord(filesDir: string, record: EventRecord): void {
  if (!recordsEnabled(filesDir)) {
    return;
  }
  try {
    const list = readAll(filesDir);
    list.push(record);
    writeAll(filesDir, trimRecords(list, Date.now(), utf8Len));
  } catch (e) {
    Logger.error(`appendRecord failed: ${JSON.stringify(e)}`);
  }
}

/** 读取最近的记录（已按 7 天过滤），最新的在前。 */
export function readRecords(filesDir: string): Array<EventRecord> {
  try {
    return trimRecords(readAll(filesDir), Date.now(), utf8Len).reverse();
  } catch (e) {
    Logger.error(`readRecords failed: ${JSON.stringify(e)}`);
    return [];
  }
}

export function clearRecords(filesDir: string): void {
  try {
    const path = filePath(filesDir);
    if (fs.accessSync(path)) {
      fs.unlinkSync(path);
    }
  } catch (e) {
    Logger.error(`clearRecords failed: ${JSON.stringify(e)}`);
  }
  deleteLegacyRecords(filesDir);
}
