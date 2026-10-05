import connection from '@ohos.net.connection';
import hilog from '@ohos.hilog';

const DOMAIN = 0x0808;
const TAG = 'ipcam.NetUtil';

let cachedLanIp = '';

/** 取局域网 IPv4(缓存一次),失败返回空串。 */
export function lanAddress(): string {
  if (cachedLanIp !== '') {
    return cachedLanIp;
  }
  return cachedLanIp;
}

export async function refreshLanAddress(): Promise<string> {
  try {
    const net: connection.NetHandle = await connection.getDefaultNet();
    const props: connection.ConnectionProperties = await connection.getConnectionProperties(net);
    const addrs: Array<connection.LinkAddress> = props.linkAddresses;
    if (addrs === undefined || addrs.length === 0) {
      return cachedLanIp;
    }
    const linkAddr: connection.LinkAddress = addrs[0];
    const netAddr: connection.NetAddress = linkAddr.address;
    const addr: string = netAddr.address;
    if (addr !== undefined && addr !== '' && addr.indexOf('.') > 0) {
      cachedLanIp = addr;
      hilog.info(DOMAIN, TAG, 'lan ip %{public}s', addr);
    }
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'get lan ip failed: %{public}s', JSON.stringify(e));
  }
  return cachedLanIp;
}
