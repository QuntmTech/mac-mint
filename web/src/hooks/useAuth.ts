import { useCallback, useEffect, useState } from 'react'
import type { RecordModel } from 'pocketbase'
import { pb } from '../lib/pb'

/** Live view of the PocketBase auth store (persisted in localStorage by the SDK). */
export const useAuth = () => {
  const [user, setUser] = useState<RecordModel | null>(pb.authStore.isValid ? pb.authStore.record : null)

  useEffect(
    () =>
      pb.authStore.onChange(() => {
        setUser(pb.authStore.isValid ? pb.authStore.record : null)
      }),
    [],
  )

  const signOut = useCallback(() => pb.authStore.clear(), [])

  return { user, isSignedIn: Boolean(user), signOut }
}
