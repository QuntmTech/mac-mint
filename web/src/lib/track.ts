type FunnelEvent = 'signup_view' | 'signup' | 'login' | 'redeem' | 'purchase'

type LandingTracker = { track: (event: string, extra?: { target?: string }) => void }

/** Records a funnel event against the visitor's landing-page variant (see public/lp.js). */
export const track = (event: FunnelEvent, target?: string) => {
  const tracker = (window as unknown as { MacMintLP?: LandingTracker }).MacMintLP
  tracker?.track(event, target ? { target } : undefined)
}
