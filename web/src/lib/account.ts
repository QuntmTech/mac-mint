import { pb } from './pb'

export type Entitlement = {
  plan: 'free' | 'pro'
  status: 'active' | 'expired' | 'revoked'
  active: boolean
  expires_at: string | null
  max_devices: number
  source: string
}

export type Device = {
  id: string
  device_id: string
  name: string
  model: string
  os_version: string
  app_version: string
  last_seen: string
}

export type AccountSnapshot = {
  user: { id: string; email: string; name: string; verified: boolean }
  entitlement: Entitlement
  devices: Device[]
  server_time: string
}

export type Release = {
  id: string
  version: string
  build: number
  min_os: string
  download_url: string
  sha256: string
  size_bytes: number
  notes: string
  published_at: string
}

const json = { 'Content-Type': 'application/json' }

export const fetchAccount = () =>
  pb.send<AccountSnapshot>('/api/macmint/me', { method: 'GET' })

export const redeemCode = (code: string) =>
  pb.send<AccountSnapshot>('/api/macmint/redeem', {
    method: 'POST',
    headers: json,
    body: JSON.stringify({ code }),
  })

export const removeDevice = (deviceId: string) =>
  pb.send<{ ok: boolean }>('/api/macmint/devices/deactivate', {
    method: 'POST',
    headers: json,
    body: JSON.stringify({ device_id: deviceId }),
  })

export const fetchLatestRelease = async (): Promise<Release | null> => {
  try {
    const list = await pb.collection('app_releases').getList<Release>(1, 1, {
      filter: 'channel = "stable"',
      sort: '-published_at,-build',
    })
    return list.items[0] ?? null
  } catch {
    return null
  }
}

export const parseDate = (value: string | null | undefined) => {
  if (!value) return null
  const date = new Date(value.replace(' ', 'T'))
  return Number.isNaN(date.getTime()) ? null : date
}

export const formatBytes = (bytes: number) => {
  if (!bytes) return ''
  const units = ['B', 'KB', 'MB', 'GB']
  const index = Math.min(units.length - 1, Math.floor(Math.log(bytes) / Math.log(1024)))
  return `${(bytes / 1024 ** index).toFixed(index ? 1 : 0)} ${units[index]}`
}
