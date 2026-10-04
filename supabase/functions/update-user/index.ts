// supabase/functions/update-user/index.ts
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}x

// auth.admin.updateUserById requires `phone` in E.164 (+<country><number>),
// but the app's phone field collects local PH-style digits (e.g.
// "09123456789" or "9123456789") — that raw value is fine for
// profiles.phone_number, but gets rejected by Supabase Auth with
// "Invalid phone number format (E.164 required)" if sent as-is.
// Converts common PH input shapes to E.164; returns null if the input
// can't be confidently normalized (caller should skip the auth phone
// update rather than guess).
function toE164Philippines(raw: string): string | null {
  const digits = raw.replace(/\D/g, '')
  if (raw.trim().startsWith('+')) {
    // Already has a country code — trust it, just strip formatting chars.
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
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const {
      userId,
      email,          // optional — only pass if you enable editing email
      phoneNumber,
      firstName,
      middleName,
      lastName,
      role,
      purok,          // optional — pass null/omit to clear it
      avatarUrl,      // optional — the profiles.avatar_url value, already uploaded by the client
      password,       // optional — only present if you add an admin "reset password" action
    } = await req.json()

    if (!userId) {
      throw new Error('userId is required')
    }
    if (!firstName || !lastName || !phoneNumber || !role) {
      throw new Error('firstName, lastName, phoneNumber, and role are required')
    }

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
      { auth: { autoRefreshToken: false, persistSession: false } },
    )

    // --- 1. Update auth.users (email/phone/password/user_metadata) ---
    // This ONLY works with the service-role key — it's why this can't
    // just be a client-side `.from('profiles').update()` call.
    //
    // Supabase Auth's "Display Name" (dashboard, and any library reading
    // user_metadata) is NOT a real column — it's read from
    // user_metadata.full_name (or .name, depending on what's reading it).
    // It has to be explicitly recomputed here on every edit, or it stays
    // stuck at whatever create-user set it to originally (first + last
    // only, no middle name, never updated again).
    const fullName = [firstName, middleName, lastName]
      .filter((part) => part && part.trim().length > 0)
      .join(' ')

    const authUpdate: Record<string, unknown> = {
      user_metadata: {
        first_name: firstName,
        middle_name: middleName ?? '',
        last_name: lastName,
        full_name: fullName,
        name: fullName, // some tools/dashboards read `name` instead of `full_name`
        role,
        ...(purok !== undefined ? { purok } : {}),
      },
    }
    if (email) {
      authUpdate.email = email
      // Skips Supabase's "confirm your new email" flow so the change
      // takes effect immediately. Remove this if you WANT the
      // confirmation-link flow instead.
      authUpdate.email_confirm = true
    }
    if (phoneNumber) {
      const e164Phone = toE164Philippines(phoneNumber)
      if (!e164Phone) {
        throw new Error(
          `Could not convert phone number "${phoneNumber}" to E.164 format. ` +
          `Expected an 11-digit number starting with 0 (e.g. 09123456789) ` +
          `or a number that already includes a country code.`,
        )
      }
      authUpdate.phone = e164Phone
    }
    if (password) authUpdate.password = password

    const { data: authData, error: authError } =
      await supabaseAdmin.auth.admin.updateUserById(userId, authUpdate)

    if (authError) {
      throw new Error(`Auth update failed: ${authError.message}`)
    }

    // --- 2. Update the profiles row (service-role client bypasses RLS,
    // so this always succeeds if the row exists — no more silent RLS
    // no-ops like the client-side `.select()` empty-array check was
    // catching before) ---
    const profileUpdate: Record<string, unknown> = {
      first_name: firstName,
      middle_name: middleName ?? '',
      last_name: lastName,
      phone_number: phoneNumber,
      role,
      purok: purok ?? null,
    }
    if (email) profileUpdate.email = email
    if (avatarUrl !== undefined) profileUpdate.avatar_url = avatarUrl

    const { data: profileData, error: profileError } = await supabaseAdmin
      .from('profiles')
      .update(profileUpdate)
      .eq('id', userId)
      .select()
      .single()

    if (profileError) {
      // Auth side already succeeded at this point — surface this clearly
      // as a partial-failure warning rather than a generic error, so the
      // caller/admin knows auth and profile may now be out of sync.
      throw new Error(
        `Auth updated, but profile update failed: ${profileError.message}`,
      )
    }

    return new Response(
      JSON.stringify({ id: authData.user.id, profile: profileData }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 },
    )
  } catch (error) {
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : String(error) }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 },
    )
  }
})