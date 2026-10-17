// Fresh installs need website links rather than PocketBase's administrative auth screens.
// Preserve any operator-customized template, including the existing MacMint production copy.
migrate(app => {
  const users = app.findCollectionByNameOrId("users")
  for (const [field, subject, action, label] of [
    ["verificationTemplate", "Verify your MacMint email", "verify-email", "Verify email"],
    ["resetPasswordTemplate", "Reset your MacMint password", "reset-password", "Reset password"],
  ]) {
    const current = users[field]
    if (!current || !current.body || current.body.indexOf("/_/#/auth/") >= 0) {
      users[field] = { subject, body: '<p>Hello,</p><p><a href="{APP_URL}/' + action + '?token={TOKEN}" target="_blank" rel="noopener">' + label + '</a></p><p>If you did not request this email, you can ignore it.</p><p>The MacMint team</p>' }
    }
  }
  app.save(users)
}, () => { /* Preserve working links on rollback; never revert live auth/token settings. */ })
