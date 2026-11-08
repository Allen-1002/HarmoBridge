import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Logger } from './Logger';

/**
 * 扩展进程（NotificationSubscriberExtAbility）与 UI 进程之间的共享记录。
 * 两者属于同一 HAP 模块，context.filesDir 指向同一沙箱目录；用追加写入的 JSON Lines 文件交换数据，
 * 避免 preferences 等进程内缓存导致跨进程读不到。
 *
 * 记录只保存在本机沙箱中，仅用于第一阶段在 App 内展示“是否真的收到了系统通知”。
 */
export interface EventRecord {
  kind: string; // 'publish' | 'cancel' | 'destroy'
  recordTime: number;
  hashCode?: string;
  bundleName?: string;
  appName?: string;
  title?: string;
  text?: string;
  deliveryTime?: number;
  slotType?: number;
  appIndex?: number;
  cancelHashCodes?: Array<string>;
}

const FILE_NAME = 'received_events.jsonl';
const MAX_READ = 200;

function filePath(filesDir: string): string {
  return `${filesDir}/${FILE_NAME}`;
}

export function appendRecord(filesDir: string, record: EventRecord): void {
  let file: fs.File | undefined = undefined;
  try {
    file = fs.openSync(filePath(filesDir), fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND);
    fs.writeSync(file.fd, JSON.stringify(record) + '\n');
  } catch (e) {
    Logger.error(`appendRecord failed: ${JSON.stringify(e)}`);
  } finally {
    if (file !== undefined) {
      fs.closeSync(file);
    }
  }
}

/** 读取最近的记录，最新的在前。 */
export function readRecords(filesDir: string): Array<EventRecord> {
  const path = filePath(filesDir);
  const result: Array<EventRecord> = [];
  try {
    if (!fs.accessSync(path)) {
      return result;
    }
    const buf = new ArrayBuffer(fs.statSync(path).size);
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    fs.readSync(file.fd, buf);
    fs.closeSync(file);
    const content = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
    const lines = content.split('\n');
    for (let i = lines.length - 1; i >= 0 && result.length < MAX_READ; i--) {
      const line = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      try {
        result.push(JSON.parse(line) as EventRecord);
      } catch (e) {
        Logger.warn('skip malformed record line');
      }
    }
  } catch (e) {
    Logger.error(`readRecords failed: ${JSON.stringify(e)}`);
  }
  return result;
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
}
