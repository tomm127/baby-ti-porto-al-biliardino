import { buildGroupQueue, generateAllGroupMatches, type Group as EngineGroup, type OrderingMode } from '../domain/index.ts';
import { ensureAnonymousPlayerSession, hasSupabaseConfig, supabase } from './supabase.ts';
import { dispatchPendingPushes } from './notifications.ts';
import { syncServerClock } from './time.ts';
import { requireOnline } from './useConnectivity.ts';

export type TournamentStatus = 'draft' | 'active' | 'completed' | 'archived';
export type MatchStatus = 'scheduled' | 'queued' | 'called' | 'ready' | 'playing' | 'awaiting_result' | 'finished' | 'postponed' | 'cancelled' | 'forfeit';

export interface TournamentRow {
  id: string;
  name: string;
  slug: string;
  status: TournamentStatus;
  phase: 'groups' | 'knockout' | 'completed';
  started_at: string | null;
}

export interface TournamentSettingsRow {
  tournament_id: string;
  ordering_mode: OrderingMode;
  qualifiers_per_group: number;
  knockout_enabled: boolean;
  third_place_enabled: boolean;
  pause_enabled: boolean;
  team_pin_enabled: boolean;
  emergency_paused: boolean;
  emergency_paused_at: string | null;
}

export interface TeamRow {
  id: string;
  tournament_id: string;
  name: string;
  status: 'active' | 'withdrawn';
}

export interface GroupRow {
  id: string;
  tournament_id: string;
  name: string;
  sort_order: number;
}

export interface GroupTeamRow {
  id: string;
  tournament_id: string;
  group_id: string;
  team_id: string;
  seed: number | null;
  lot_order: number;
}

export interface MatchRuleRow {
  id: string;
  tournament_id: string;
  scope: 'group' | 'knockout' | 'final' | 'third_place';
  duration_seconds: number | null;
  goal_target: number | null;
  golden_goal_on_tie: boolean;
}

export interface FieldRow {
  id: string;
  tournament_id: string;
  name: string;
  sort_order: number;
  is_active: boolean;
}

export interface KnockoutRoundRow {
  id: string;
  tournament_id: string;
  round_number: number;
  name: string;
  sort_order: number;
}

export interface QualifierRow {
  tournament_id: string;
  team_id: string;
  group_id: string;
  group_rank: number;
  global_seed: number;
  played: number;
  points: number;
  goal_difference: number;
  goals_for: number;
  points_per_game: number;
  goal_difference_per_game: number;
  goals_for_per_game: number;
  lot_order: number;
}

export interface MatchRow {
  id: string;
  tournament_id: string;
  stage: 'group' | 'knockout' | 'final' | 'third_place';
  status: MatchStatus;
  group_id: string | null;
  knockout_round_id: string | null;
  bracket_slot: number | null;
  sequence_number: number | null;
  queue_position: number | null;
  team1_id: string | null;
  team2_id: string | null;
  team1_source_match_id: string | null;
  team2_source_match_id: string | null;
  team1_source_loser_match_id: string | null;
  team2_source_loser_match_id: string | null;
  field_id: string | null;
  duration_seconds: number | null;
  goal_target: number | null;
  pause_allowed: boolean;
  golden_goal_on_tie: boolean;
  timer_remaining_seconds: number | null;
  timer_started_at: string | null;
  paused_at: string | null;
  score_team1: number | null;
  score_team2: number | null;
  winner_team_id: string | null;
  started_at: string | null;
  called_at: string | null;
  ended_at: string | null;
}

export interface StandingRowDb {
  tournament_id: string;
  group_id: string;
  team_id: string;
  team_name: string;
  played: number;
  wins: number;
  draws: number;
  losses: number;
  goals_for: number;
  goals_against: number;
  goal_difference: number;
  points: number;
  lot_order: number;
}

export interface TournamentBundle {
  tournament: TournamentRow;
  settings: TournamentSettingsRow;
  teams: TeamRow[];
  groups: GroupRow[];
  groupTeams: GroupTeamRow[];
  fields: FieldRow[];
  rules: MatchRuleRow[];
  knockoutRounds: KnockoutRoundRow[];
  qualifiers: QualifierRow[];
  matches: MatchRow[];
  standings: StandingRowDb[];
}

export interface TeamInput { name: string; pin?: string; }
export interface CreateTournamentInput {
  name: string;
  slug: string;
  teams: TeamInput[];
  groupCount: number;
  /** Optional custom names in display/order sequence. Defaults to Girone A, Girone B, ... */
  groupNames?: string[];
  /** Optional explicit group index for every team (0-based). If omitted, teams are balanced round-robin. */
  teamGroupIndexes?: number[];
  fieldNames: string[];
  orderingMode: OrderingMode;
  qualifiersPerGroup: number;
  knockoutEnabled: boolean;
  thirdPlaceEnabled: boolean;
  pauseEnabled: boolean;
  teamPinEnabled: boolean;
  rules: {
    group: { durationSeconds: number | null; goalTarget: number | null };
    knockout: { durationSeconds: number | null; goalTarget: number | null };
    final: { durationSeconds: number | null; goalTarget: number | null };
    third_place: { durationSeconds: number | null; goalTarget: number | null };
  };
}

function client() {
  if (!supabase || !hasSupabaseConfig) throw new Error('Supabase non configurato. Crea il file .env.local.');
  requireOnline();
  return supabase;
}

const CACHE_PREFIX = 'baby-biliardino:v1';

function cacheWrite<T>(key: string, value: T) {
  if (typeof window === 'undefined') return;
  try { window.localStorage.setItem(`${CACHE_PREFIX}:${key}`, JSON.stringify({ savedAt: new Date().toISOString(), value })); } catch { /* storage unavailable */ }
}

function cacheRead<T>(key: string): { savedAt: string; value: T } | null {
  if (typeof window === 'undefined') return null;
  try {
    const raw = window.localStorage.getItem(`${CACHE_PREFIX}:${key}`);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as { savedAt?: string; value?: T };
    if (!parsed.savedAt || parsed.value === undefined) return null;
    return { savedAt: parsed.savedAt, value: parsed.value };
  } catch { return null; }
}

function assignmentKey(tournamentId: string) { return `assignment:${tournamentId}`; }
function bundleKey(slug: string) { return `bundle:${slug}`; }
const ACTIVE_TOURNAMENTS_KEY = 'active-tournaments';

function cacheAssignment(tournamentId: string, teamId: string | null) { cacheWrite(assignmentKey(tournamentId), teamId); }
function readCachedAssignment(tournamentId: string) { return cacheRead<string | null>(assignmentKey(tournamentId))?.value ?? null; }


function message(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

async function dispatchPushNonFatal() {
  try { await dispatchPendingPushes(); }
  catch (error) { console.warn('Invio push non disponibile:', error); }
}

export function slugify(value: string) {
  return value
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '') || 'torneo';
}

export interface ResilientListResult<T> { data: T; source: 'network' | 'cache'; cachedAt: string | null; }
export interface ResilientBundleResult { bundle: TournamentBundle; source: 'network' | 'cache'; cachedAt: string | null; }

export async function listActiveTournaments(): Promise<TournamentRow[]> {
  requireOnline();
  await ensureAnonymousPlayerSession();
  const { data, error } = await client()
    .from('tournaments')
    .select('id,name,slug,status,phase,started_at')
    .eq('status', 'active')
    .order('started_at', { ascending: false });
  if (error) throw error;
  const rows = (data ?? []) as TournamentRow[];
  cacheWrite(ACTIVE_TOURNAMENTS_KEY, rows);
  return rows;
}

export async function listActiveTournamentsResilient(): Promise<ResilientListResult<TournamentRow[]>> {
  try {
    const data = await listActiveTournaments();
    return { data, source: 'network', cachedAt: null };
  } catch (error) {
    const cached = cacheRead<TournamentRow[]>(ACTIVE_TOURNAMENTS_KEY);
    if (cached) return { data: cached.value, source: 'cache', cachedAt: cached.savedAt };
    throw error;
  }
}

export async function listAdminTournaments(): Promise<TournamentRow[]> {
  const { data, error } = await client()
    .from('tournaments')
    .select('id,name,slug,status,phase,started_at')
    .order('created_at', { ascending: false });
  if (error) throw error;
  return (data ?? []) as TournamentRow[];
}

export async function isCurrentUserAdmin(): Promise<boolean> {
  const { data, error } = await client().rpc('is_admin');
  if (error) throw error;
  return Boolean(data);
}

type SnapshotPayload = TournamentBundle & { server_now?: string; my_team_id?: string | null };

function snapshotToBundle(payload: SnapshotPayload): TournamentBundle {
  return {
    tournament: payload.tournament,
    settings: payload.settings,
    teams: payload.teams ?? [],
    groups: payload.groups ?? [],
    groupTeams: payload.groupTeams ?? [],
    fields: payload.fields ?? [],
    rules: payload.rules ?? [],
    knockoutRounds: payload.knockoutRounds ?? [],
    qualifiers: payload.qualifiers ?? [],
    matches: payload.matches ?? [],
    standings: payload.standings ?? [],
  };
}

async function snapshotRpc(name: 'get_tournament_snapshot' | 'get_tournament_snapshot_by_id', args: Record<string, unknown>) {
  const started = Date.now();
  const { data, error } = await client().rpc(name, args);
  const received = Date.now();
  if (error) throw error;
  const payload = data as SnapshotPayload;
  syncServerClock(payload.server_now, started, received);
  const bundle = snapshotToBundle(payload);
  cacheWrite(bundleKey(bundle.tournament.slug), bundle);
  cacheAssignment(bundle.tournament.id, payload.my_team_id ?? null);
  return bundle;
}

export async function loadTournamentBundle(slug: string): Promise<TournamentBundle> {
  requireOnline();
  await ensureAnonymousPlayerSession();
  return snapshotRpc('get_tournament_snapshot', { p_slug: slug });
}

export async function loadTournamentBundleResilient(slug: string): Promise<ResilientBundleResult> {
  try {
    const bundle = await loadTournamentBundle(slug);
    return { bundle, source: 'network', cachedAt: null };
  } catch (error) {
    const cached = cacheRead<TournamentBundle>(bundleKey(slug));
    if (cached) return { bundle: cached.value, source: 'cache', cachedAt: cached.savedAt };
    throw error;
  }
}

export async function loadTournamentBundleById(id: string, knownTournament?: TournamentRow): Promise<TournamentBundle> {
  void knownTournament;
  return snapshotRpc('get_tournament_snapshot_by_id', { p_tournament_id: id });
}

export async function getMyTeamAssignment(tournamentId: string): Promise<string | null> {
  // Snapshot reads already cache the assignment, so this normally costs zero
  // additional network requests.
  return readCachedAssignment(tournamentId);
}

export async function claimTeam(teamId: string, pin?: string) {
  const { data: team, error: teamError } = await client().from('teams').select('tournament_id').eq('id', teamId).single();
  if (teamError) throw teamError;
  const { error } = await client().rpc('claim_team', { p_team_id: teamId, p_pin: pin || null });
  if (error) throw error;
  cacheAssignment(String(team.tournament_id), teamId);
  await dispatchPushNonFatal();
}

export async function leaveTeam(tournamentId: string) {
  const { error } = await client().rpc('leave_team', { p_tournament_id: tournamentId });
  if (error) throw error;
  cacheAssignment(tournamentId, null);
}

export async function startMatch(matchId: string): Promise<MatchRow> {
  const { data, error } = await client().rpc('start_match', { p_match_id: matchId });
  if (error) throw error;
  return data as MatchRow;
}

export async function pauseMatch(matchId: string): Promise<MatchRow> {
  const { data, error } = await client().rpc('pause_match', { p_match_id: matchId });
  if (error) throw error;
  return data as MatchRow;
}

export async function resumeMatch(matchId: string): Promise<MatchRow> {
  const { data, error } = await client().rpc('resume_match', { p_match_id: matchId });
  if (error) throw error;
  return data as MatchRow;
}

export async function markTimerExpired(matchId: string): Promise<MatchRow> {
  const { data, error } = await client().rpc('mark_timer_expired', { p_match_id: matchId });
  if (error) throw error;
  return data as MatchRow;
}

export async function endMatchEarly(matchId: string): Promise<MatchRow> {
  const { data, error } = await client().rpc('end_match_early', { p_match_id: matchId });
  if (error) throw error;
  return data as MatchRow;
}

export async function submitMatchResult(matchId: string, scoreTeam1: number, scoreTeam2: number): Promise<MatchRow> {
  const { data, error } = await client().rpc('submit_match_result', {
    p_match_id: matchId,
    p_score_team1: scoreTeam1,
    p_score_team2: scoreTeam2,
  });
  if (error) throw error;
  await dispatchPushNonFatal();
  return data as MatchRow;
}



export async function adminSetEmergencyPause(tournamentId: string, paused: boolean) {
  const { data, error } = await client().rpc('admin_set_emergency_pause', {
    p_tournament_id: tournamentId,
    p_paused: paused,
  });
  if (error) throw error;
  await dispatchPushNonFatal();
  return Boolean(data);
}

export async function adminReorderQueue(tournamentId: string, orderedMatchIds: string[]) {
  const { data, error } = await client().rpc('admin_reorder_queue', { p_tournament_id: tournamentId, p_match_ids: orderedMatchIds });
  if (error) throw error;
  await dispatchPushNonFatal();
  return Number(data ?? 0);
}

export async function adminForfeitMatch(matchId: string, loserTeamId: string) {
  const { data, error } = await client().rpc('admin_forfeit_match', { p_match_id: matchId, p_loser_team_id: loserTeamId });
  if (error) throw error;
  await dispatchPushNonFatal();
  return data as MatchRow;
}

export async function adminCancelMatch(matchId: string) {
  const { data, error } = await client().rpc('admin_cancel_match', { p_match_id: matchId });
  if (error) throw error;
  await dispatchPushNonFatal();
  return data as MatchRow;
}

export async function adminAssignMatchField(matchId: string, fieldId: string) {
  const { data, error } = await client().rpc('admin_assign_match_field', { p_match_id: matchId, p_field_id: fieldId });
  if (error) throw error;
  await dispatchPushNonFatal();
  return data as MatchRow;
}

export async function adminRenameTeam(teamId: string, name: string) {
  const clean = name.trim();
  if (!clean) throw new Error('Il nome della squadra non può essere vuoto.');
  const { error } = await client().from('teams').update({ name: clean }).eq('id', teamId);
  if (error) throw error;
}

export async function adminSetTeamPin(teamId: string, pin: string) {
  const { error } = await client().rpc('admin_set_team_pin', { p_team_id: teamId, p_pin: pin.trim() || null });
  if (error) throw error;
}

export async function adminAddTeam(tournamentId: string, groupId: string | null, name: string, pin?: string) {
  const before = await loadTournamentBundleById(tournamentId);
  const { data, error } = await client().rpc('admin_add_team', { p_tournament_id: tournamentId, p_group_id: groupId, p_name: name.trim(), p_pin: pin?.trim() || null });
  if (error) throw error;
  if (before.tournament.status === 'draft') await regenerateGroupSchedule(tournamentId);
  else await dispatchPushNonFatal();
  return String(data);
}

export async function adminBulkAddTeams(
  tournamentId: string,
  groupId: string | null,
  teams: { name: string; pin?: string }[],
) {
  const before = await loadTournamentBundleById(tournamentId);
  const { data, error } = await client().rpc('admin_bulk_add_teams', {
    p_tournament_id: tournamentId,
    p_group_id: groupId,
    p_teams: teams.map((team) => ({ name: team.name.trim(), pin: team.pin?.trim() || null })),
  });
  if (error) throw error;
  if (before.tournament.status === 'draft') await regenerateGroupSchedule(tournamentId);
  else await dispatchPushNonFatal();
  return Number(data ?? 0);
}

export async function adminApplyGroupLayout(
  tournamentId: string,
  assignments: { team_id: string; group_id: string | null }[],
) {
  const before = await loadTournamentBundleById(tournamentId);
  const { data, error } = await client().rpc('admin_apply_group_layout', {
    p_tournament_id: tournamentId,
    p_assignments: assignments,
  });
  if (error) throw error;
  if (before.tournament.status === 'draft') await regenerateGroupSchedule(tournamentId);
  else await dispatchPushNonFatal();
  return Number(data ?? 0);
}

export async function adminWithdrawTeam(tournamentId: string, teamId: string) {
  const before = await loadTournamentBundleById(tournamentId);
  const { data, error } = await client().rpc('admin_withdraw_team', { p_team_id: teamId });
  if (error) throw error;
  if (before.tournament.status === 'draft') await regenerateGroupSchedule(tournamentId);
  else await dispatchPushNonFatal();
  return Number(data ?? 0);
}

export async function adminRestoreTeam(tournamentId: string, teamId: string) {
  const before = await loadTournamentBundleById(tournamentId);
  const { data, error } = await client().rpc('admin_restore_team', { p_team_id: teamId });
  if (error) throw error;
  if (before.tournament.status === 'draft') await regenerateGroupSchedule(tournamentId);
  else await dispatchPushNonFatal();
  return Number(data ?? 0);
}

export async function adminDeleteTeamCompletely(tournamentId: string, teamId: string) {
  const before = await loadTournamentBundleById(tournamentId);
  const { error } = await client().rpc('admin_delete_team_completely', { p_team_id: teamId });
  if (error) throw error;
  if (before.tournament.status === 'draft') await regenerateGroupSchedule(tournamentId);
  else await dispatchPushNonFatal();
}

export async function adminForceMoveTeamToGroup(tournamentId: string, teamId: string, groupId: string | null) {
  const before = await loadTournamentBundleById(tournamentId);
  const { data, error } = await client().rpc('admin_force_move_team_group', { p_team_id: teamId, p_group_id: groupId });
  if (error) throw error;
  if (before.tournament.status === 'draft') await regenerateGroupSchedule(tournamentId);
  else await dispatchPushNonFatal();
  return Number(data ?? 0);
}

export async function adminAddField(tournamentId: string, name: string) {
  const { data, error } = await client().rpc('admin_add_field', { p_tournament_id: tournamentId, p_name: name.trim() });
  if (error) throw error;
  await dispatchPushNonFatal();
  return String(data);
}

export async function adminUpdateField(fieldId: string, name: string, isActive: boolean) {
  const { data, error } = await client().rpc('admin_update_field', { p_field_id: fieldId, p_name: name.trim(), p_is_active: isActive });
  if (error) throw error;
  await dispatchPushNonFatal();
  return data as FieldRow;
}

export interface AdminRulesInput {
  pauseEnabled: boolean;
  qualifiersPerGroup: number;
  thirdPlaceEnabled: boolean;
  teamPinEnabled: boolean;
  group: { durationSeconds: number | null; goalTarget: number | null };
  knockout: { durationSeconds: number | null; goalTarget: number | null };
  final: { durationSeconds: number | null; goalTarget: number | null };
  thirdPlace: { durationSeconds: number | null; goalTarget: number | null };
}

export async function adminUpdateTournamentRules(tournamentId: string, input: AdminRulesInput) {
  const { error } = await client().rpc('admin_update_tournament_rules', {
    p_tournament_id: tournamentId,
    p_pause_enabled: input.pauseEnabled,
    p_qualifiers_per_group: input.qualifiersPerGroup,
    p_third_place_enabled: input.thirdPlaceEnabled,
    p_team_pin_enabled: input.teamPinEnabled,
    p_group_duration: input.group.durationSeconds,
    p_group_goal: input.group.goalTarget,
    p_knockout_duration: input.knockout.durationSeconds,
    p_knockout_goal: input.knockout.goalTarget,
    p_final_duration: input.final.durationSeconds,
    p_final_goal: input.final.goalTarget,
    p_third_duration: input.thirdPlace.durationSeconds,
    p_third_goal: input.thirdPlace.goalTarget,
  });
  if (error) throw error;
}

export async function adminPostponeMatch(matchId: string) {
  const { data, error } = await client().rpc('admin_postpone_match', { p_match_id: matchId });
  if (error) throw error;
  await dispatchPushNonFatal();
  return data as MatchRow;
}

export async function adminStartTournament(tournamentId: string) {
  const { data, error } = await client().rpc('admin_start_tournament', { p_tournament_id: tournamentId });
  if (error) throw error;
  await dispatchPushNonFatal();
  return Number(data ?? 0);
}

export async function adminResetTournamentMatches(tournamentId: string) {
  const { error } = await client().rpc('admin_reset_tournament_matches', {
    p_tournament_id: tournamentId,
  });
  if (error) throw error;

  // The reset RPC deliberately leaves the tournament empty and in draft.
  // Rebuild the group schedule as SCHEDULED matches. They remain unassigned
  // until the admin explicitly presses INIZIA TORNEO.
  return regenerateGroupSchedule(tournamentId);
}

export async function adminSetMatchResult(matchId: string, scoreTeam1: number, scoreTeam2: number) {
  const { data, error } = await client().rpc('admin_set_match_result', {
    p_match_id: matchId,
    p_score_team1: scoreTeam1,
    p_score_team2: scoreTeam2,
  });
  if (error) throw error;
  await dispatchPushNonFatal();
  return data as MatchRow;
}

export async function adminUpdateMatchResult(matchId: string, scoreTeam1: number, scoreTeam2: number) {
  const { data, error } = await client().rpc('admin_update_match_result', {
    p_match_id: matchId,
    p_score_team1: scoreTeam1,
    p_score_team2: scoreTeam2,
  });
  if (error) throw error;
  return data as MatchRow;
}

export async function adminGenerateKnockout(tournamentId: string) {
  const { data, error } = await client().rpc('admin_generate_knockout', { p_tournament_id: tournamentId });
  if (error) throw error;
  await dispatchPushNonFatal();
  return Number(data ?? 0);
}

export async function adminRenameTournament(tournamentId: string, name: string) {
  const clean = name.trim();
  if (!clean) throw new Error('Il nome del torneo non può essere vuoto.');
  const { error } = await client().from('tournaments').update({ name: clean }).eq('id', tournamentId);
  if (error) throw error;
}

export async function adminRenameGroup(groupId: string, name: string) {
  const clean = name.trim();
  if (!clean) throw new Error('Il nome del girone non può essere vuoto.');
  const { error } = await client().from('groups').update({ name: clean }).eq('id', groupId);
  if (error) throw error;
}

export async function adminMoveTeamToGroup(tournamentId: string, teamId: string, groupId: string) {
  const current = await loadTournamentBundleById(tournamentId);
  if (current.tournament.status !== 'draft') throw new Error('Puoi spostare automaticamente le squadre solo prima dell’avvio.');
  const membership = current.groupTeams.find((gt) => gt.team_id === teamId);
  if (!membership) throw new Error('Squadra non assegnata a un girone.');
  if (membership.group_id === groupId) return;
  const sourceSize = current.groupTeams.filter((gt) => gt.group_id === membership.group_id).length;
  if (sourceSize - 1 < current.settings.qualifiers_per_group) {
    throw new Error(`Lo spostamento lascerebbe un girone con meno di ${current.settings.qualifiers_per_group} squadre.`);
  }

  const { error } = await client()
    .from('group_teams')
    .update({ group_id: groupId })
    .eq('tournament_id', tournamentId)
    .eq('team_id', teamId);
  if (error) throw error;
  await regenerateGroupSchedule(tournamentId);
}

export async function regenerateGroupSchedule(tournamentId: string) {
  const bundle = await loadTournamentBundleById(tournamentId);
  if (bundle.tournament.status !== 'draft') throw new Error('Il calendario può essere rigenerato automaticamente solo prima dell’avvio.');

  const teamById = new Map(bundle.teams.map((t) => [t.id, t]));
  const engineGroups: EngineGroup[] = bundle.groups.map((g) => ({
    id: g.id,
    name: g.name,
    sortOrder: g.sort_order,
    teams: bundle.groupTeams
      .filter((gt) => gt.group_id === g.id)
      .map((gt) => ({ id: gt.team_id, name: teamById.get(gt.team_id)?.name ?? gt.team_id, lotOrder: gt.lot_order })),
  }));

  const schedules = generateAllGroupMatches(engineGroups);
  const queue = buildGroupQueue(engineGroups, schedules, bundle.settings.ordering_mode);
  const payload = queue.map((m, index) => ({
    group_id: m.groupId,
    team1_id: m.team1Id,
    team2_id: m.team2Id,
    sequence_number: index + 1,
  }));

  const { error } = await client().rpc('admin_install_group_schedule', {
    p_tournament_id: tournamentId,
    p_matches: payload,
  });
  if (error) throw error;
  return payload.length;
}

export async function createTournament(input: CreateTournamentInput): Promise<TournamentRow> {
  const c = client();
  const { data: sessionData } = await c.auth.getSession();
  const userId = sessionData.session?.user.id;
  if (!userId) throw new Error('Sessione admin non disponibile.');
  if (input.teams.length < 2) throw new Error('Inserisci almeno 2 squadre.');
  const normalizedTeamNames = input.teams.map((team) => team.name.trim().toLocaleLowerCase('it'));
  if (normalizedTeamNames.some((name) => !name)) throw new Error('I nomi delle squadre non possono essere vuoti.');
  if (new Set(normalizedTeamNames).size !== normalizedTeamNames.length) throw new Error('I nomi delle squadre devono essere unici.');
  const effectiveGroupCount = input.groupNames?.length || input.groupCount;
  if (effectiveGroupCount < 1) throw new Error('Serve almeno un girone.');
  if (effectiveGroupCount > 26) throw new Error('La V1 supporta fino a 26 gironi.');
  if (effectiveGroupCount > input.teams.length) throw new Error('Non puoi avere più gironi che squadre.');
  if (input.groupNames && input.groupNames.some((name) => !name.trim())) throw new Error('I nomi dei gironi non possono essere vuoti.');
  const normalizedGroupNames = (input.groupNames ?? []).map((name) => name.trim().toLocaleLowerCase('it'));
  if (new Set(normalizedGroupNames).size !== normalizedGroupNames.length) throw new Error('I nomi dei gironi devono essere unici.');
  if (input.teamGroupIndexes) {
    if (input.teamGroupIndexes.length !== input.teams.length) throw new Error("L'assegnazione manuale dei gironi non corrisponde al numero di squadre.");
    if (input.teamGroupIndexes.some((index) => !Number.isInteger(index) || index < 0 || index >= effectiveGroupCount)) throw new Error('Assegnazione manuale dei gironi non valida.');
  }
  if (input.fieldNames.length < 1) throw new Error('Serve almeno un campo.');
  for (const [scope, rule] of Object.entries(input.rules)) {
    if (rule.durationSeconds == null && rule.goalTarget == null) throw new Error(`La regola ${scope} deve avere un timer, un target goal o entrambi.`);
    if (rule.durationSeconds != null && (!Number.isFinite(rule.durationSeconds) || rule.durationSeconds <= 0)) throw new Error(`Timer non valido per ${scope}.`);
    if (rule.goalTarget != null && (!Number.isInteger(rule.goalTarget) || rule.goalTarget <= 0)) throw new Error(`Target goal non valido per ${scope}.`);
  }

  let tournamentId: string | null = null;
  try {
    const { data: tournament, error: tournamentError } = await c
      .from('tournaments')
      .insert({ name: input.name.trim(), slug: slugify(input.slug || input.name), created_by: userId })
      .select('id,name,slug,status,phase,started_at')
      .single();
    if (tournamentError) throw tournamentError;
    tournamentId = tournament.id as string;

    const { error: settingsError } = await c
      .from('tournament_settings')
      .update({
        ordering_mode: input.orderingMode,
        qualifiers_per_group: input.qualifiersPerGroup,
        knockout_enabled: input.knockoutEnabled,
        third_place_enabled: input.thirdPlaceEnabled,
        pause_enabled: input.pauseEnabled,
        team_pin_enabled: input.teamPinEnabled,
      })
      .eq('tournament_id', tournamentId);
    if (settingsError) throw settingsError;

    for (const [scope, rule] of Object.entries(input.rules)) {
      const { error } = await c
        .from('match_rule_sets')
        .update({
          duration_seconds: rule.durationSeconds,
          goal_target: rule.goalTarget,
          golden_goal_on_tie: scope !== 'group',
        })
        .eq('tournament_id', tournamentId)
        .eq('scope', scope);
      if (error) throw error;
    }

    const { data: teams, error: teamsError } = await c
      .from('teams')
      .insert(input.teams.map((t) => ({ tournament_id: tournamentId, name: t.name.trim() })))
      .select('id,tournament_id,name,status');
    if (teamsError) throw teamsError;

    const groupsPayload = Array.from({ length: effectiveGroupCount }, (_, i) => ({
      tournament_id: tournamentId,
      name: input.groupNames?.[i]?.trim() || `Girone ${String.fromCharCode(65 + i)}`,
      sort_order: i + 1,
    }));
    const { data: groups, error: groupsError } = await c
      .from('groups')
      .insert(groupsPayload)
      .select('id,tournament_id,name,sort_order');
    if (groupsError) throw groupsError;

    const insertedTeams = teams as TeamRow[];
    const insertedGroups = groups as GroupRow[];
    const sourceIndexByName = new Map(input.teams.map((team, index) => [team.name.trim().toLocaleLowerCase('it'), index]));
    const groupSizes = new Array(insertedGroups.length).fill(0);
    const assignments = insertedTeams.map((team) => {
      const sourceIndex = sourceIndexByName.get(team.name.trim().toLocaleLowerCase('it'));
      if (sourceIndex == null) throw new Error(`Impossibile ricostruire l'ordine della squadra ${team.name}.`);
      const groupIndex = input.teamGroupIndexes?.[sourceIndex] ?? (sourceIndex % insertedGroups.length);
      groupSizes[groupIndex]++;
      return {
        tournament_id: tournamentId,
        group_id: insertedGroups[groupIndex].id,
        team_id: team.id,
        seed: groupSizes[groupIndex],
      };
    });
    const minGroupSize = Math.min(...groupSizes);
    if (input.qualifiersPerGroup > minGroupSize) {
      throw new Error(`Con questa distribuzione ogni girone deve avere almeno ${input.qualifiersPerGroup} squadre.`);
    }

    const { error: assignmentError } = await c.from('group_teams').insert(assignments);
    if (assignmentError) throw assignmentError;

    const { error: fieldError } = await c.from('fields').insert(
      input.fieldNames.map((name, i) => ({ tournament_id: tournamentId, name: name.trim(), sort_order: i + 1 })),
    );
    if (fieldError) throw fieldError;

    if (input.teamPinEnabled) {
      for (const insertedTeam of insertedTeams) {
        const sourceIndex = sourceIndexByName.get(insertedTeam.name.trim().toLocaleLowerCase('it'));
        const pin = sourceIndex == null ? undefined : input.teams[sourceIndex].pin?.trim();
        if (!pin) throw new Error(`Manca il PIN per ${insertedTeam.name}.`);
        const { error } = await c.rpc('admin_set_team_pin', { p_team_id: insertedTeam.id, p_pin: pin });
        if (error) throw error;
      }
    }

    await regenerateGroupSchedule(tournamentId);
    return tournament as TournamentRow;
  } catch (error) {
    if (tournamentId) await c.from('tournaments').delete().eq('id', tournamentId);
    throw new Error(message(error));
  }
}
