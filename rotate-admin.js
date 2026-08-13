// Set the admin account's password to whatever MEDUSA_ADMIN_PASSWORD currently
// holds. Run on every boot where the account already exists.
//
// Medusa's CLI has no path for this. `medusa user -e ... -p ...` refuses once the
// account is there, and there is no `medusa user --update` and no password-reset
// command, so on every competing listing the password a deployer typed into the
// Railway variable panel is applied exactly once, on the very first boot, and
// editing it afterwards changes nothing while the form still shows the new value.
//
// `updateProvider` is the same call the "reset password" flow ends in, so the
// stored scrypt hash is written the way the emailpass provider expects.
export default async function ({ container }) {
  const email = process.env.MEDUSA_ADMIN_EMAIL
  const password = process.env.MEDUSA_ADMIN_PASSWORD

  if (!email || !password) {
    throw new Error("MEDUSA_ADMIN_EMAIL and MEDUSA_ADMIN_PASSWORD must both be set")
  }

  const auth = container.resolve("auth")
  const result = await auth.updateProvider("emailpass", {
    entity_id: email,
    password,
  })

  if (!result?.success) {
    throw new Error(`could not update the admin password: ${result?.error ?? "unknown error"}`)
  }

  console.log(`[rotate-admin] password set for ${email}`)
}
