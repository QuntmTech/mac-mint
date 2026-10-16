import PocketBase from 'pocketbase'

export const PB_URL = import.meta.env.VITE_PB_URL ?? 'https://macmint.cloudpod.pro'

export const pb = new PocketBase(PB_URL)
pb.autoCancellation(false)

/** Extracts a human-readable message from a PocketBase ClientResponseError (or anything else). */
export const errorMessage = (error: unknown, fallback = 'Something went wrong. Please try again.') => {
  const err = error as { status?: number; response?: { message?: string; data?: Record<string, { message?: string }> } }
  if (err?.status === 0) return "Couldn't reach MacMint. Check your connection and try again."
  if (err?.status === 429) return 'Too many attempts. Wait a minute and try again.'
  const fields = err?.response?.data ?? {}
  const firstField = Object.entries(fields).find(([, value]) => value?.message)
  if (firstField) {
    const [name, value] = firstField
    return `${name.charAt(0).toUpperCase()}${name.slice(1)}: ${value.message}`
  }
  return err?.response?.message || fallback
}
