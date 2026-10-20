import { BrowserRouter, Route, Routes } from 'react-router-dom'
import { useEffect } from 'react'
import { Layout } from './components/Layout'
import { Account } from './pages/Account'
import { Download } from './pages/Download'
import { ForgotPassword } from './pages/ForgotPassword'
import { Login } from './pages/Login'
import { NotFound } from './pages/NotFound'
import { ResetPassword } from './pages/ResetPassword'
import { Signup } from './pages/Signup'
import { Start } from './pages/Start'
import { VerifyEmail } from './pages/VerifyEmail'
import { Welcome } from './pages/Welcome'

// A client-side return to / must leave the account router for the static homepage.
const MarketingHome = () => {
  useEffect(() => {
    if (!import.meta.env.DEV) window.location.reload()
  }, [])
  return <a href="/">Open the MacMint homepage</a>
}

export const App = () => (
  <BrowserRouter>
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<MarketingHome />} />
        <Route path="login" element={<Login />} />
        <Route path="signup" element={<Signup />} />
        <Route path="forgot-password" element={<ForgotPassword />} />
        <Route path="reset-password" element={<ResetPassword />} />
        <Route path="verify-email" element={<VerifyEmail />} />
        <Route path="account" element={<Account />} />
        <Route path="start" element={<Start />} />
        <Route path="welcome" element={<Welcome />} />
        <Route path="download" element={<Download />} />
        <Route path="*" element={<NotFound />} />
      </Route>
    </Routes>
  </BrowserRouter>
)
