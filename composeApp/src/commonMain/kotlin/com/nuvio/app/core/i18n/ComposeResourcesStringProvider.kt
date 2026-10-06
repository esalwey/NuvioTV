package com.nuvio.app.core.i18n

import kotlinx.coroutines.runBlocking
import nuvio.composeapp.generated.resources.Res
import nuvio.composeapp.generated.resources.addon_already_installed
import nuvio.composeapp.generated.resources.addon_invalid_url
import nuvio.composeapp.generated.resources.addon_load_manifest_failed
import nuvio.composeapp.generated.resources.addons_error_enter_url
import nuvio.composeapp.generated.resources.addons_manifest_missing_field
import nuvio.composeapp.generated.resources.generic_addon
import nuvio.composeapp.generated.resources.network_empty_response_body
import nuvio.composeapp.generated.resources.network_request_failed_http
import nuvio.composeapp.generated.resources.profile_primary_addons_required
import nuvio.composeapp.generated.resources.details_load_failed_all_addons
import nuvio.composeapp.generated.resources.details_no_addon_meta
import nuvio.composeapp.generated.resources.streams_failed_to_load_scraper
import nuvio.composeapp.generated.resources.streams_plugin_repository_fallback
import nuvio.composeapp.generated.resources.player_addon_subtitle_display_format
import nuvio.composeapp.generated.resources.compose_player_no_subtitles_found
import nuvio.composeapp.generated.resources.trakt_progress_load_failed
import nuvio.composeapp.generated.resources.profile_pin_set_requires_internet
import nuvio.composeapp.generated.resources.profile_pin_set_failed
import nuvio.composeapp.generated.resources.profile_pin_clear_requires_internet
import nuvio.composeapp.generated.resources.profile_pin_clear_failed
import nuvio.composeapp.generated.resources.profile_pin_offline_verification_requires_online
import nuvio.composeapp.generated.resources.profile_pin_changed_requires_refresh
import nuvio.composeapp.generated.resources.pin_incorrect
import nuvio.composeapp.generated.resources.collections_folder_count
import nuvio.composeapp.generated.resources.home_catalog_default_title
import nuvio.composeapp.generated.resources.discover_catalog_context
import nuvio.composeapp.generated.resources.discover_empty_load_failed_message
import nuvio.composeapp.generated.resources.search_error_no_results_for_catalog
import nuvio.composeapp.generated.resources.collections_folder_addon_not_found
import nuvio.composeapp.generated.resources.collections_folder_trakt_movie_list
import nuvio.composeapp.generated.resources.collections_folder_trakt_series_list
import nuvio.composeapp.generated.resources.collections_tab_all
import nuvio.composeapp.generated.resources.trakt_library_load_failed
import nuvio.composeapp.generated.resources.trakt_watchlist
import nuvio.composeapp.generated.resources.trakt_list_fallback_title
import nuvio.composeapp.generated.resources.trakt_error_request_failed
import nuvio.composeapp.generated.resources.trakt_error_empty_response
import nuvio.composeapp.generated.resources.trakt_error_add_watchlist_failed
import nuvio.composeapp.generated.resources.trakt_error_add_list_failed
import nuvio.composeapp.generated.resources.trakt_error_missing_ids
import nuvio.composeapp.generated.resources.trakt_error_authorization_expired
import nuvio.composeapp.generated.resources.trakt_error_list_not_found
import nuvio.composeapp.generated.resources.trakt_error_list_limit_reached
import nuvio.composeapp.generated.resources.trakt_error_rate_limit_reached
import nuvio.composeapp.generated.resources.library_local_tab_title
import nuvio.composeapp.generated.resources.library_other
import nuvio.composeapp.generated.resources.trakt_lists_update_failed
import nuvio.composeapp.generated.resources.catalog_load_failed
import nuvio.composeapp.generated.resources.downloads_enqueue_started
import nuvio.composeapp.generated.resources.downloads_enqueue_replaced
import nuvio.composeapp.generated.resources.downloads_enqueue_missing_url
import nuvio.composeapp.generated.resources.downloads_enqueue_unsupported_format
import nuvio.composeapp.generated.resources.download_failed
import nuvio.composeapp.generated.resources.notifications_episode_release_body_code
import nuvio.composeapp.generated.resources.notifications_episode_release_body_code_title
import nuvio.composeapp.generated.resources.notifications_episode_release_body_generic
import nuvio.composeapp.generated.resources.notifications_episode_release_body_title
import nuvio.composeapp.generated.resources.notifications_test_preview_body
import nuvio.composeapp.generated.resources.notifications_test_send_failed
import nuvio.composeapp.generated.resources.notifications_test_sent_for
import nuvio.composeapp.generated.resources.settings_notifications_permission_disabled
import nuvio.composeapp.generated.resources.settings_notifications_test_requires_saved_show
import nuvio.composeapp.generated.resources.details_runtime_hours_minutes
import nuvio.composeapp.generated.resources.details_runtime_hours_only
import nuvio.composeapp.generated.resources.details_runtime_minutes_only
import nuvio.composeapp.generated.resources.generic_trailer
import nuvio.composeapp.generated.resources.generic_unknown
import nuvio.composeapp.generated.resources.meta_section_actions_description
import nuvio.composeapp.generated.resources.meta_section_actions_title
import nuvio.composeapp.generated.resources.meta_section_cast_description
import nuvio.composeapp.generated.resources.meta_section_collection_description
import nuvio.composeapp.generated.resources.meta_section_collection_title
import nuvio.composeapp.generated.resources.meta_section_comments_description
import nuvio.composeapp.generated.resources.meta_section_details_description
import nuvio.composeapp.generated.resources.meta_section_details_title
import nuvio.composeapp.generated.resources.meta_section_episodes_description
import nuvio.composeapp.generated.resources.meta_section_more_like_this_description
import nuvio.composeapp.generated.resources.meta_section_more_like_this_title
import nuvio.composeapp.generated.resources.meta_section_overview_description
import nuvio.composeapp.generated.resources.meta_section_overview_title
import nuvio.composeapp.generated.resources.meta_section_production_description
import nuvio.composeapp.generated.resources.meta_section_production_title
import nuvio.composeapp.generated.resources.meta_section_trailers_description
import nuvio.composeapp.generated.resources.person_role_creator
import nuvio.composeapp.generated.resources.person_role_director
import nuvio.composeapp.generated.resources.person_role_writer
import nuvio.composeapp.generated.resources.settings_meta_cast
import nuvio.composeapp.generated.resources.settings_meta_comments
import nuvio.composeapp.generated.resources.settings_meta_episodes
import nuvio.composeapp.generated.resources.settings_meta_trailers
import nuvio.composeapp.generated.resources.source_embedded
import nuvio.composeapp.generated.resources.stream_default_name
import nuvio.composeapp.generated.resources.trailer_season_label
import nuvio.composeapp.generated.resources.collections_editor_tmdb_discover
import nuvio.composeapp.generated.resources.collections_tmdb_api_key_required
import nuvio.composeapp.generated.resources.collections_tmdb_collection_not_found
import nuvio.composeapp.generated.resources.collections_tmdb_company_not_found
import nuvio.composeapp.generated.resources.collections_tmdb_discover_no_data
import nuvio.composeapp.generated.resources.collections_tmdb_list_not_found
import nuvio.composeapp.generated.resources.collections_tmdb_missing_collection_id
import nuvio.composeapp.generated.resources.collections_tmdb_missing_list_id
import nuvio.composeapp.generated.resources.collections_tmdb_missing_person_id
import nuvio.composeapp.generated.resources.collections_tmdb_network_not_found
import nuvio.composeapp.generated.resources.collections_tmdb_person_credits_not_found
import nuvio.composeapp.generated.resources.collections_tmdb_person_not_found
import nuvio.composeapp.generated.resources.auth_account_deletion_failed
import nuvio.composeapp.generated.resources.auth_sign_in_failed
import nuvio.composeapp.generated.resources.auth_sign_out_failed
import nuvio.composeapp.generated.resources.auth_sign_up_failed
import nuvio.composeapp.generated.resources.collections_editor_media_movies_suffix
import nuvio.composeapp.generated.resources.collections_editor_media_series_suffix
import nuvio.composeapp.generated.resources.collections_editor_resolved_trakt_list
import nuvio.composeapp.generated.resources.collections_editor_tmdb_collection_title_format
import nuvio.composeapp.generated.resources.collections_editor_tmdb_director_title_format
import nuvio.composeapp.generated.resources.collections_editor_tmdb_invalid_id_error
import nuvio.composeapp.generated.resources.collections_editor_tmdb_list_title_format
import nuvio.composeapp.generated.resources.collections_editor_tmdb_load_error
import nuvio.composeapp.generated.resources.collections_editor_tmdb_network_title_format
import nuvio.composeapp.generated.resources.collections_editor_tmdb_person_title_format
import nuvio.composeapp.generated.resources.collections_editor_tmdb_production_title_format
import nuvio.composeapp.generated.resources.collections_editor_trakt_fallback_title
import nuvio.composeapp.generated.resources.collections_editor_trakt_id_url_required
import nuvio.composeapp.generated.resources.collections_editor_trakt_input_required
import nuvio.composeapp.generated.resources.collections_editor_trakt_list_title_format
import nuvio.composeapp.generated.resources.collections_editor_trakt_load_error
import nuvio.composeapp.generated.resources.collections_editor_trakt_load_failed
import nuvio.composeapp.generated.resources.collections_editor_trakt_no_lists_found
import nuvio.composeapp.generated.resources.collections_import_error_collection_blank_id
import nuvio.composeapp.generated.resources.collections_import_error_collection_blank_title
import nuvio.composeapp.generated.resources.collections_import_error_collection_duplicate_id
import nuvio.composeapp.generated.resources.collections_import_error_empty_json
import nuvio.composeapp.generated.resources.collections_import_error_folder_blank_id
import nuvio.composeapp.generated.resources.collections_import_error_folder_blank_title
import nuvio.composeapp.generated.resources.collections_import_error_folder_duplicate_id
import nuvio.composeapp.generated.resources.collections_import_error_invalid_json
import nuvio.composeapp.generated.resources.collections_import_error_source_blank_fields
import nuvio.composeapp.generated.resources.collections_import_error_trakt_list_id
import nuvio.composeapp.generated.resources.collections_trakt_credentials_missing
import nuvio.composeapp.generated.resources.collections_trakt_error_with_code
import nuvio.composeapp.generated.resources.collections_trakt_invalid_list_id_or_url
import nuvio.composeapp.generated.resources.collections_trakt_list_items_count
import nuvio.composeapp.generated.resources.collections_trakt_list_likes_count
import nuvio.composeapp.generated.resources.collections_trakt_list_not_found_or_private
import nuvio.composeapp.generated.resources.collections_trakt_missing_list_id
import nuvio.composeapp.generated.resources.collections_trakt_missing_numeric_id
import nuvio.composeapp.generated.resources.collections_trakt_public_list
import nuvio.composeapp.generated.resources.collections_trakt_rate_limit_reached
import nuvio.composeapp.generated.resources.collections_trakt_request_failed
import nuvio.composeapp.generated.resources.details_comments_trakt_load_failed_with_code
import nuvio.composeapp.generated.resources.trakt_authorization_denied
import nuvio.composeapp.generated.resources.trakt_complete_sign_in_browser
import nuvio.composeapp.generated.resources.trakt_connected_status
import nuvio.composeapp.generated.resources.trakt_authorization_expired_reconnect
import nuvio.composeapp.generated.resources.trakt_disconnected_status
import nuvio.composeapp.generated.resources.trakt_invalid_callback
import nuvio.composeapp.generated.resources.trakt_invalid_callback_state
import nuvio.composeapp.generated.resources.trakt_invalid_token_response
import nuvio.composeapp.generated.resources.trakt_missing_auth_code
import nuvio.composeapp.generated.resources.trakt_missing_credentials
import nuvio.composeapp.generated.resources.trakt_sign_in_complete_failed
import nuvio.composeapp.generated.resources.trakt_user_fallback
import nuvio.composeapp.generated.resources.action_play
import nuvio.composeapp.generated.resources.action_play_episode
import nuvio.composeapp.generated.resources.action_resume
import nuvio.composeapp.generated.resources.action_resume_episode
import nuvio.composeapp.generated.resources.compose_player_episode_code_episode_only
import nuvio.composeapp.generated.resources.compose_player_episode_code_full
import nuvio.composeapp.generated.resources.compose_player_no_subtitle_lines_found
import nuvio.composeapp.generated.resources.compose_player_subtitle_lines_load_error
import nuvio.composeapp.generated.resources.continue_watching_up_next
import nuvio.composeapp.generated.resources.continue_watching_up_next_episode
import nuvio.composeapp.generated.resources.date_month_april
import nuvio.composeapp.generated.resources.date_month_august
import nuvio.composeapp.generated.resources.date_month_december
import nuvio.composeapp.generated.resources.date_month_february
import nuvio.composeapp.generated.resources.date_month_january
import nuvio.composeapp.generated.resources.date_month_july
import nuvio.composeapp.generated.resources.date_month_june
import nuvio.composeapp.generated.resources.date_month_march
import nuvio.composeapp.generated.resources.date_month_may
import nuvio.composeapp.generated.resources.date_month_november
import nuvio.composeapp.generated.resources.date_month_october
import nuvio.composeapp.generated.resources.date_month_september
import nuvio.composeapp.generated.resources.date_month_short_apr
import nuvio.composeapp.generated.resources.date_month_short_aug
import nuvio.composeapp.generated.resources.date_month_short_dec
import nuvio.composeapp.generated.resources.date_month_short_feb
import nuvio.composeapp.generated.resources.date_month_short_jan
import nuvio.composeapp.generated.resources.date_month_short_jul
import nuvio.composeapp.generated.resources.date_month_short_jun
import nuvio.composeapp.generated.resources.date_month_short_mar
import nuvio.composeapp.generated.resources.date_month_short_may
import nuvio.composeapp.generated.resources.date_month_short_nov
import nuvio.composeapp.generated.resources.date_month_short_oct
import nuvio.composeapp.generated.resources.date_month_short_sep
import nuvio.composeapp.generated.resources.media_anime
import nuvio.composeapp.generated.resources.media_channels
import nuvio.composeapp.generated.resources.media_movie
import nuvio.composeapp.generated.resources.media_movies
import nuvio.composeapp.generated.resources.media_series
import nuvio.composeapp.generated.resources.media_tv
import nuvio.composeapp.generated.resources.p2p_error_unknown
import nuvio.composeapp.generated.resources.settings_stream_badge_enter_url
import nuvio.composeapp.generated.resources.settings_stream_badge_import_failed
import nuvio.composeapp.generated.resources.settings_stream_badge_import_limit
import nuvio.composeapp.generated.resources.settings_stream_badge_url_scheme_invalid
import nuvio.composeapp.generated.resources.unit_bytes_b
import nuvio.composeapp.generated.resources.unit_bytes_gb
import nuvio.composeapp.generated.resources.unit_bytes_kb
import nuvio.composeapp.generated.resources.unit_bytes_mb
import nuvio.composeapp.generated.resources.debrid_missing_api_key
import nuvio.composeapp.generated.resources.debrid_not_cached
import nuvio.composeapp.generated.resources.debrid_resolve_failed
import nuvio.composeapp.generated.resources.debrid_stream_stale
import nuvio.composeapp.generated.resources.cloud_library_playback_disabled
import nuvio.composeapp.generated.resources.cloud_library_provider_unavailable
import nuvio.composeapp.generated.resources.external_player_android_system
import org.jetbrains.compose.resources.StringResource
import org.jetbrains.compose.resources.getString

/**
 * Phone-app [StringProvider] backed by Compose Resources, preserving the app's bundled
 * locales. Install once at startup via [install]. The shared [LocalizedUiText] helpers call
 * through this and fall back to their inline English text if a lookup throws.
 */
object ComposeResourcesStringProvider : StringProvider {

    /** Register this provider as the process-wide string source. Idempotent. */
    fun install() {
        LocalizedStrings.provider = this
    }

    override fun get(key: StringKey, vararg args: Any?): String? {
        val resource = resourceFor(key)
        val formatArgs = args.map { it ?: "" }.toTypedArray()
        return runCatching {
            runBlocking {
                if (formatArgs.isEmpty()) getString(resource)
                else getString(resource, *formatArgs)
            }
        }.getOrNull()
    }

    private fun resourceFor(key: StringKey): StringResource = when (key) {
        StringKey.addon_already_installed -> Res.string.addon_already_installed
        StringKey.addon_invalid_url -> Res.string.addon_invalid_url
        StringKey.addon_load_manifest_failed -> Res.string.addon_load_manifest_failed
        StringKey.addons_error_enter_url -> Res.string.addons_error_enter_url
        StringKey.addons_manifest_missing_field -> Res.string.addons_manifest_missing_field
        StringKey.generic_addon -> Res.string.generic_addon
        StringKey.network_empty_response_body -> Res.string.network_empty_response_body
        StringKey.network_request_failed_http -> Res.string.network_request_failed_http
        StringKey.profile_primary_addons_required -> Res.string.profile_primary_addons_required
        StringKey.details_runtime_hours_minutes -> Res.string.details_runtime_hours_minutes
        StringKey.details_runtime_hours_only -> Res.string.details_runtime_hours_only
        StringKey.details_runtime_minutes_only -> Res.string.details_runtime_minutes_only
        StringKey.generic_trailer -> Res.string.generic_trailer
        StringKey.generic_unknown -> Res.string.generic_unknown
        StringKey.meta_section_actions_description -> Res.string.meta_section_actions_description
        StringKey.meta_section_actions_title -> Res.string.meta_section_actions_title
        StringKey.meta_section_cast_description -> Res.string.meta_section_cast_description
        StringKey.meta_section_collection_description -> Res.string.meta_section_collection_description
        StringKey.meta_section_collection_title -> Res.string.meta_section_collection_title
        StringKey.meta_section_comments_description -> Res.string.meta_section_comments_description
        StringKey.meta_section_details_description -> Res.string.meta_section_details_description
        StringKey.meta_section_details_title -> Res.string.meta_section_details_title
        StringKey.meta_section_episodes_description -> Res.string.meta_section_episodes_description
        StringKey.meta_section_more_like_this_description -> Res.string.meta_section_more_like_this_description
        StringKey.meta_section_more_like_this_title -> Res.string.meta_section_more_like_this_title
        StringKey.meta_section_overview_description -> Res.string.meta_section_overview_description
        StringKey.meta_section_overview_title -> Res.string.meta_section_overview_title
        StringKey.meta_section_production_description -> Res.string.meta_section_production_description
        StringKey.meta_section_production_title -> Res.string.meta_section_production_title
        StringKey.meta_section_trailers_description -> Res.string.meta_section_trailers_description
        StringKey.person_role_creator -> Res.string.person_role_creator
        StringKey.person_role_director -> Res.string.person_role_director
        StringKey.person_role_writer -> Res.string.person_role_writer
        StringKey.settings_meta_cast -> Res.string.settings_meta_cast
        StringKey.settings_meta_comments -> Res.string.settings_meta_comments
        StringKey.settings_meta_episodes -> Res.string.settings_meta_episodes
        StringKey.settings_meta_trailers -> Res.string.settings_meta_trailers
        StringKey.source_embedded -> Res.string.source_embedded
        StringKey.stream_default_name -> Res.string.stream_default_name
        StringKey.trailer_season_label -> Res.string.trailer_season_label
        StringKey.collections_editor_tmdb_discover -> Res.string.collections_editor_tmdb_discover
        StringKey.collections_tmdb_api_key_required -> Res.string.collections_tmdb_api_key_required
        StringKey.collections_tmdb_collection_not_found -> Res.string.collections_tmdb_collection_not_found
        StringKey.collections_tmdb_company_not_found -> Res.string.collections_tmdb_company_not_found
        StringKey.collections_tmdb_discover_no_data -> Res.string.collections_tmdb_discover_no_data
        StringKey.collections_tmdb_list_not_found -> Res.string.collections_tmdb_list_not_found
        StringKey.collections_tmdb_missing_collection_id -> Res.string.collections_tmdb_missing_collection_id
        StringKey.collections_tmdb_missing_list_id -> Res.string.collections_tmdb_missing_list_id
        StringKey.collections_tmdb_missing_person_id -> Res.string.collections_tmdb_missing_person_id
        StringKey.collections_tmdb_network_not_found -> Res.string.collections_tmdb_network_not_found
        StringKey.collections_tmdb_person_credits_not_found -> Res.string.collections_tmdb_person_credits_not_found
        StringKey.collections_tmdb_person_not_found -> Res.string.collections_tmdb_person_not_found
        StringKey.auth_account_deletion_failed -> Res.string.auth_account_deletion_failed
        StringKey.auth_sign_in_failed -> Res.string.auth_sign_in_failed
        StringKey.auth_sign_out_failed -> Res.string.auth_sign_out_failed
        StringKey.auth_sign_up_failed -> Res.string.auth_sign_up_failed
        StringKey.collections_editor_media_movies_suffix -> Res.string.collections_editor_media_movies_suffix
        StringKey.collections_editor_media_series_suffix -> Res.string.collections_editor_media_series_suffix
        StringKey.collections_editor_resolved_trakt_list -> Res.string.collections_editor_resolved_trakt_list
        StringKey.collections_editor_tmdb_collection_title_format -> Res.string.collections_editor_tmdb_collection_title_format
        StringKey.collections_editor_tmdb_director_title_format -> Res.string.collections_editor_tmdb_director_title_format
        StringKey.collections_editor_tmdb_invalid_id_error -> Res.string.collections_editor_tmdb_invalid_id_error
        StringKey.collections_editor_tmdb_list_title_format -> Res.string.collections_editor_tmdb_list_title_format
        StringKey.collections_editor_tmdb_load_error -> Res.string.collections_editor_tmdb_load_error
        StringKey.collections_editor_tmdb_network_title_format -> Res.string.collections_editor_tmdb_network_title_format
        StringKey.collections_editor_tmdb_person_title_format -> Res.string.collections_editor_tmdb_person_title_format
        StringKey.collections_editor_tmdb_production_title_format -> Res.string.collections_editor_tmdb_production_title_format
        StringKey.collections_editor_trakt_fallback_title -> Res.string.collections_editor_trakt_fallback_title
        StringKey.collections_editor_trakt_id_url_required -> Res.string.collections_editor_trakt_id_url_required
        StringKey.collections_editor_trakt_input_required -> Res.string.collections_editor_trakt_input_required
        StringKey.collections_editor_trakt_list_title_format -> Res.string.collections_editor_trakt_list_title_format
        StringKey.collections_editor_trakt_load_error -> Res.string.collections_editor_trakt_load_error
        StringKey.collections_editor_trakt_load_failed -> Res.string.collections_editor_trakt_load_failed
        StringKey.collections_editor_trakt_no_lists_found -> Res.string.collections_editor_trakt_no_lists_found
        StringKey.collections_import_error_collection_blank_id -> Res.string.collections_import_error_collection_blank_id
        StringKey.collections_import_error_collection_blank_title -> Res.string.collections_import_error_collection_blank_title
        StringKey.collections_import_error_collection_duplicate_id -> Res.string.collections_import_error_collection_duplicate_id
        StringKey.collections_import_error_empty_json -> Res.string.collections_import_error_empty_json
        StringKey.collections_import_error_folder_blank_id -> Res.string.collections_import_error_folder_blank_id
        StringKey.collections_import_error_folder_blank_title -> Res.string.collections_import_error_folder_blank_title
        StringKey.collections_import_error_folder_duplicate_id -> Res.string.collections_import_error_folder_duplicate_id
        StringKey.collections_import_error_invalid_json -> Res.string.collections_import_error_invalid_json
        StringKey.collections_import_error_source_blank_fields -> Res.string.collections_import_error_source_blank_fields
        StringKey.collections_import_error_trakt_list_id -> Res.string.collections_import_error_trakt_list_id
        StringKey.collections_trakt_credentials_missing -> Res.string.collections_trakt_credentials_missing
        StringKey.collections_trakt_error_with_code -> Res.string.collections_trakt_error_with_code
        StringKey.collections_trakt_invalid_list_id_or_url -> Res.string.collections_trakt_invalid_list_id_or_url
        StringKey.collections_trakt_list_items_count -> Res.string.collections_trakt_list_items_count
        StringKey.collections_trakt_list_likes_count -> Res.string.collections_trakt_list_likes_count
        StringKey.collections_trakt_list_not_found_or_private -> Res.string.collections_trakt_list_not_found_or_private
        StringKey.collections_trakt_missing_list_id -> Res.string.collections_trakt_missing_list_id
        StringKey.collections_trakt_missing_numeric_id -> Res.string.collections_trakt_missing_numeric_id
        StringKey.collections_trakt_public_list -> Res.string.collections_trakt_public_list
        StringKey.collections_trakt_rate_limit_reached -> Res.string.collections_trakt_rate_limit_reached
        StringKey.collections_trakt_request_failed -> Res.string.collections_trakt_request_failed
        StringKey.details_comments_trakt_load_failed_with_code -> Res.string.details_comments_trakt_load_failed_with_code
        StringKey.trakt_authorization_denied -> Res.string.trakt_authorization_denied
        StringKey.trakt_complete_sign_in_browser -> Res.string.trakt_complete_sign_in_browser
        StringKey.trakt_connected_status -> Res.string.trakt_connected_status
        StringKey.trakt_authorization_expired_reconnect -> Res.string.trakt_authorization_expired_reconnect
        StringKey.trakt_disconnected_status -> Res.string.trakt_disconnected_status
        StringKey.trakt_invalid_callback -> Res.string.trakt_invalid_callback
        StringKey.trakt_invalid_callback_state -> Res.string.trakt_invalid_callback_state
        StringKey.trakt_invalid_token_response -> Res.string.trakt_invalid_token_response
        StringKey.trakt_missing_auth_code -> Res.string.trakt_missing_auth_code
        StringKey.trakt_missing_credentials -> Res.string.trakt_missing_credentials
        StringKey.trakt_sign_in_complete_failed -> Res.string.trakt_sign_in_complete_failed
        StringKey.trakt_user_fallback -> Res.string.trakt_user_fallback
        StringKey.action_play -> Res.string.action_play
        StringKey.action_play_episode -> Res.string.action_play_episode
        StringKey.action_resume -> Res.string.action_resume
        StringKey.action_resume_episode -> Res.string.action_resume_episode
        StringKey.compose_player_episode_code_episode_only -> Res.string.compose_player_episode_code_episode_only
        StringKey.compose_player_episode_code_full -> Res.string.compose_player_episode_code_full
        StringKey.compose_player_no_subtitle_lines_found -> Res.string.compose_player_no_subtitle_lines_found
        StringKey.compose_player_subtitle_lines_load_error -> Res.string.compose_player_subtitle_lines_load_error
        StringKey.continue_watching_up_next -> Res.string.continue_watching_up_next
        StringKey.continue_watching_up_next_episode -> Res.string.continue_watching_up_next_episode
        StringKey.date_month_january -> Res.string.date_month_january
        StringKey.date_month_february -> Res.string.date_month_february
        StringKey.date_month_march -> Res.string.date_month_march
        StringKey.date_month_april -> Res.string.date_month_april
        StringKey.date_month_may -> Res.string.date_month_may
        StringKey.date_month_june -> Res.string.date_month_june
        StringKey.date_month_july -> Res.string.date_month_july
        StringKey.date_month_august -> Res.string.date_month_august
        StringKey.date_month_september -> Res.string.date_month_september
        StringKey.date_month_october -> Res.string.date_month_october
        StringKey.date_month_november -> Res.string.date_month_november
        StringKey.date_month_december -> Res.string.date_month_december
        StringKey.date_month_short_jan -> Res.string.date_month_short_jan
        StringKey.date_month_short_feb -> Res.string.date_month_short_feb
        StringKey.date_month_short_mar -> Res.string.date_month_short_mar
        StringKey.date_month_short_apr -> Res.string.date_month_short_apr
        StringKey.date_month_short_may -> Res.string.date_month_short_may
        StringKey.date_month_short_jun -> Res.string.date_month_short_jun
        StringKey.date_month_short_jul -> Res.string.date_month_short_jul
        StringKey.date_month_short_aug -> Res.string.date_month_short_aug
        StringKey.date_month_short_sep -> Res.string.date_month_short_sep
        StringKey.date_month_short_oct -> Res.string.date_month_short_oct
        StringKey.date_month_short_nov -> Res.string.date_month_short_nov
        StringKey.date_month_short_dec -> Res.string.date_month_short_dec
        StringKey.media_anime -> Res.string.media_anime
        StringKey.media_channels -> Res.string.media_channels
        StringKey.media_movie -> Res.string.media_movie
        StringKey.media_movies -> Res.string.media_movies
        StringKey.media_series -> Res.string.media_series
        StringKey.media_tv -> Res.string.media_tv
        StringKey.p2p_error_unknown -> Res.string.p2p_error_unknown
        StringKey.settings_stream_badge_enter_url -> Res.string.settings_stream_badge_enter_url
        StringKey.settings_stream_badge_import_failed -> Res.string.settings_stream_badge_import_failed
        StringKey.settings_stream_badge_import_limit -> Res.string.settings_stream_badge_import_limit
        StringKey.settings_stream_badge_url_scheme_invalid -> Res.string.settings_stream_badge_url_scheme_invalid
        StringKey.unit_bytes_b -> Res.string.unit_bytes_b
        StringKey.unit_bytes_gb -> Res.string.unit_bytes_gb
        StringKey.unit_bytes_kb -> Res.string.unit_bytes_kb
        StringKey.unit_bytes_mb -> Res.string.unit_bytes_mb
        StringKey.debrid_missing_api_key -> Res.string.debrid_missing_api_key
        StringKey.debrid_not_cached -> Res.string.debrid_not_cached
        StringKey.debrid_resolve_failed -> Res.string.debrid_resolve_failed
        StringKey.debrid_stream_stale -> Res.string.debrid_stream_stale
        StringKey.cloud_library_playback_disabled -> Res.string.cloud_library_playback_disabled
        StringKey.cloud_library_provider_unavailable -> Res.string.cloud_library_provider_unavailable
        StringKey.external_player_android_system -> Res.string.external_player_android_system
        StringKey.details_no_addon_meta -> Res.string.details_no_addon_meta
        StringKey.details_load_failed_all_addons -> Res.string.details_load_failed_all_addons
        StringKey.streams_failed_to_load_scraper -> Res.string.streams_failed_to_load_scraper
        StringKey.streams_plugin_repository_fallback -> Res.string.streams_plugin_repository_fallback
        StringKey.player_addon_subtitle_display_format -> Res.string.player_addon_subtitle_display_format
        StringKey.compose_player_no_subtitles_found -> Res.string.compose_player_no_subtitles_found
        StringKey.trakt_progress_load_failed -> Res.string.trakt_progress_load_failed
        StringKey.profile_pin_set_requires_internet -> Res.string.profile_pin_set_requires_internet
        StringKey.profile_pin_set_failed -> Res.string.profile_pin_set_failed
        StringKey.profile_pin_clear_requires_internet -> Res.string.profile_pin_clear_requires_internet
        StringKey.profile_pin_clear_failed -> Res.string.profile_pin_clear_failed
        StringKey.profile_pin_offline_verification_requires_online -> Res.string.profile_pin_offline_verification_requires_online
        StringKey.profile_pin_changed_requires_refresh -> Res.string.profile_pin_changed_requires_refresh
        StringKey.pin_incorrect -> Res.string.pin_incorrect
        StringKey.collections_folder_count -> Res.string.collections_folder_count
        StringKey.home_catalog_default_title -> Res.string.home_catalog_default_title
        StringKey.discover_catalog_context -> Res.string.discover_catalog_context
        StringKey.discover_empty_load_failed_message -> Res.string.discover_empty_load_failed_message
        StringKey.search_error_no_results_for_catalog -> Res.string.search_error_no_results_for_catalog
        StringKey.collections_folder_addon_not_found -> Res.string.collections_folder_addon_not_found
        StringKey.collections_folder_trakt_movie_list -> Res.string.collections_folder_trakt_movie_list
        StringKey.collections_folder_trakt_series_list -> Res.string.collections_folder_trakt_series_list
        StringKey.collections_tab_all -> Res.string.collections_tab_all
        StringKey.trakt_library_load_failed -> Res.string.trakt_library_load_failed
        StringKey.trakt_watchlist -> Res.string.trakt_watchlist
        StringKey.trakt_list_fallback_title -> Res.string.trakt_list_fallback_title
        StringKey.trakt_error_request_failed -> Res.string.trakt_error_request_failed
        StringKey.trakt_error_empty_response -> Res.string.trakt_error_empty_response
        StringKey.trakt_error_add_watchlist_failed -> Res.string.trakt_error_add_watchlist_failed
        StringKey.trakt_error_add_list_failed -> Res.string.trakt_error_add_list_failed
        StringKey.trakt_error_missing_ids -> Res.string.trakt_error_missing_ids
        StringKey.trakt_error_authorization_expired -> Res.string.trakt_error_authorization_expired
        StringKey.trakt_error_list_not_found -> Res.string.trakt_error_list_not_found
        StringKey.trakt_error_list_limit_reached -> Res.string.trakt_error_list_limit_reached
        StringKey.trakt_error_rate_limit_reached -> Res.string.trakt_error_rate_limit_reached
        StringKey.library_local_tab_title -> Res.string.library_local_tab_title
        StringKey.library_other -> Res.string.library_other
        StringKey.trakt_lists_update_failed -> Res.string.trakt_lists_update_failed
        StringKey.catalog_load_failed -> Res.string.catalog_load_failed
        StringKey.downloads_enqueue_started -> Res.string.downloads_enqueue_started
        StringKey.downloads_enqueue_replaced -> Res.string.downloads_enqueue_replaced
        StringKey.downloads_enqueue_missing_url -> Res.string.downloads_enqueue_missing_url
        StringKey.downloads_enqueue_unsupported_format -> Res.string.downloads_enqueue_unsupported_format
        StringKey.download_failed -> Res.string.download_failed
        StringKey.notifications_episode_release_body_code -> Res.string.notifications_episode_release_body_code
        StringKey.notifications_episode_release_body_code_title -> Res.string.notifications_episode_release_body_code_title
        StringKey.notifications_episode_release_body_generic -> Res.string.notifications_episode_release_body_generic
        StringKey.notifications_episode_release_body_title -> Res.string.notifications_episode_release_body_title
        StringKey.notifications_test_preview_body -> Res.string.notifications_test_preview_body
        StringKey.notifications_test_send_failed -> Res.string.notifications_test_send_failed
        StringKey.notifications_test_sent_for -> Res.string.notifications_test_sent_for
        StringKey.settings_notifications_permission_disabled -> Res.string.settings_notifications_permission_disabled
        StringKey.settings_notifications_test_requires_saved_show -> Res.string.settings_notifications_test_requires_saved_show
    }
}
