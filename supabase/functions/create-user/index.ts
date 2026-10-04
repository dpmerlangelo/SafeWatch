import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// auth.admin.createUser requires `phone` in E.164 (+<country><number>),
// but the app's phone field collects local PH-style digits (e.g.
// "09123456789" or "9123456789"). Same conversion used in update-user —
// keep both in sync if you ever change this. Returns null if the input
// can't be confidently normalized (caller should skip the phone field
// rather than guess and get a 400 back from Auth).
function toE164Philippines(raw: string): string | null {
  const digits = raw.replace(/\D/g, '')
  if (raw.trim().startsWith('+')) {
    return '+' + digits
  }
  if (digits.length === 12 && digits.startsWith('63')) {
    return '+' + digits // 639123456789
  }
  if (digits.length === 11 && digits.startsWith('0')) {
    return '+63' + digits.slice(1) // 09123456789 -> +639123456789
  }
  if (digits.length === 10 && digits.startsWith('9')) {
    return '+63' + digits // 9123456789 -> +639123456789
  }
  return null
}

serve(async (req) => {
  // Handle CORS preflight request
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    // 1. Authenticate the caller using their JWT header
    const authHeader = req.headers.get('Authorization')!
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authHeader } } }
    )

    // 2. Fetch logged-in user details
    const { data: { user }, error: userError } = await supabaseClient.auth.getUser()
    if (userError || !user) throw new Error('Unauthorized')

    // 3. Confirm caller is an Admin from your database profiles table
    const { data: profile } = await supabaseClient
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .single()

    if (!profile || profile.role !== 'Admin') {
      throw new Error('Forbidden: Only admins can create employee accounts.')
    }

    // 4. Extract parameters sent from Flutter.
    // `purok` only applies to Tanod and Purok Leader — the Flutter side
    // only sends it for those roles, so it'll be undefined/null otherwise.
    const { email, password, firstName, middleName, lastName, phoneNumber, role, purok } = await req.json()

    // Supabase Auth's "Display Name" (dashboard, and any library reading
    // user_metadata) is NOT a real column — it's read from
    // user_metadata.full_name (or .name, depending on what's reading it).
    // Without this, new users get no display name at all until someone
    // edits them (see update-user, which recomputes it on every edit).
    const fullName = [firstName, middleName, lastName]
      .filter((part: string | undefined) => part && part.trim().length > 0)
      .join(' ')

    // Convert the local PH-style number to E.164 so it actually lands in
    // auth.users.phone (not just user_metadata.phone_number). Mirrors
    // update-user's handling — without this, createUser() never sets a
    // real `phone` field, and auth.users.phone stays null until the user
    // is edited once via update-user.
    //
    // Unlike update-user, this doesn't hard-fail the whole request if the
    // number can't be normalized — email/password is enough for account
    // creation to succeed, so we just skip setting `phone` on the auth
    // user in that case (phoneNumber still gets saved to user_metadata
    // and, via the profiles trigger/insert, to profiles.phone_number).
    let e164Phone: string | null = null
    if (phoneNumber) {
      e164Phone = toE164Philippines(phoneNumber)
    }

    // 5. Use Service Role Key to bypass public signup rules safely on the server
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    const { data: newUser, error: createError } = await supabaseAdmin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      ...(e164Phone ? { phone: e164Phone, phone_confirm: true } : {}),
      user_metadata: {
        first_name: firstName,
        middle_name: middleName,
        last_name: lastName,
        full_name: fullName,
        name: fullName, // some tools/dashboards read `name` instead of `full_name`
        phone_number: phoneNumber,
        role: role,
        purok: purok ?? null,
      }
    })

    if (createError) throw createError

    // NOTE: supabaseAdmin.auth.admin.createUser() resolves to
    // { data: { user: {...} }, error }. We destructured `data` above and
    // renamed it to `newUser`, so `newUser` is really `{ user: {...} }` —
    // the actual auth user record (with its id) lives at `newUser.user`,
    // not `newUser` itself. We flatten that here so the response has a
    // top-level `id` the caller can use directly, instead of nesting
    // `user` inside `user` again.
    const newUserId = newUser.user.id

    // 6. Explicitly persist purok on the profiles row.
    // Whatever trigger/mechanism turns this new auth user into a
    // `profiles` row (reading `user_metadata` above) may or may not
    // carry a `purok` column through — rather than depend on that, write
    // it directly here with the service-role client, which bypasses RLS.
    // Only touches the row when purok was actually supplied, so roles
    // that don't need one (Command Center, Task Force) never get an
    // unnecessary write.
    if (purok) {
      const { error: purokError } = await supabaseAdmin
        .from('profiles')
        .update({ purok })
        .eq('id', newUserId)

      if (purokError) {
        // The auth account + profile already exist at this point, so we
        // don't fail the whole request over this — just report it back
        // so the caller (and admin) knows the purok didn't stick.
        return new Response(
          JSON.stringify({
            success: true,
            id: newUserId,
            user: newUser.user,
            warning: `User created, but failed to save purok: ${purokError.message}`,
          }),
          {
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
            status: 200,
          }
        )
      }
    }

    // Let the caller/admin know if the phone couldn't be normalized —
    // the account was still created fine, just without a phone set on
    // the auth user (it can be fixed later via update-user, or by
    // re-entering the number in a recognized format).
    if (phoneNumber && !e164Phone) {
      return new Response(
        JSON.stringify({
          success: true,
          id: newUserId,
          user: newUser.user,
          warning: `User created, but "${phoneNumber}" could not be converted to E.164 format, so it was not set as the account's phone number.`,
        }),
        {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 200,
        }
      )
    }

    return new Response(
      JSON.stringify({ success: true, id: newUserId, user: newUser.user }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      }
    )
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    })
  }
})