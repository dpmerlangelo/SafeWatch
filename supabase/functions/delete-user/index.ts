import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
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
      throw new Error('Forbidden: Only admins can remove employee accounts.')
    }

    // 4. Extract the target user id sent from Flutter
    const { userId } = await req.json()
    if (!userId) throw new Error('Missing userId')

    // Guard against an admin accidentally deleting their own account
    // through this endpoint (they'd lose access mid-request).
    if (userId === user.id) {
      throw new Error('You cannot remove your own account.')
    }

    // 5. Service-role client — required both for auth.admin.deleteUser and
    // for removing another user's Storage objects.
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    // 6. Remove any avatar files for this user. We list the user's folder
    // instead of guessing a single filename/extension, since a past edit
    // could have uploaded a different file type than the most recent one.
    const { data: avatarFiles } = await supabaseAdmin
      .storage
      .from('avatars')
      .list(userId)

    if (avatarFiles && avatarFiles.length > 0) {
      const paths = avatarFiles.map((f) => `${userId}/${f.name}`)
      await supabaseAdmin.storage.from('avatars').remove(paths)
    }

    // 7. Delete the auth account. If profiles.id has an ON DELETE CASCADE
    // foreign key referencing auth.users(id), this also removes the
    // profile row automatically.
    const { error: deleteAuthError } = await supabaseAdmin.auth.admin.deleteUser(userId)
    if (deleteAuthError) throw deleteAuthError

    // 8. Best-effort cleanup in case there's no cascade configured —
    // deleting a row that's already gone is a no-op, not an error.
    await supabaseAdmin.from('profiles').delete().eq('id', userId)

    return new Response(JSON.stringify({ success: true }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    })
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    })
  }
})