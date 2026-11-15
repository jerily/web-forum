# Forum SQL uses explicit parameter types on both SQLite and PostgreSQL.
proc ::web::forum::field_type {name} {
    expr {$name in {created_at last_activity_at revision hidden locked} ? "bigint" : "text"}
}
proc ::web::forum::predicate {store where} {
    set terms [list [::web::user::predicate $store {}]]
    dict for {key value} $where {lappend terms [db_eq [db_col $key] [db_value $value -type [field_type $key]]]}
    db_and {*}$terms
}
proc ::web::forum::values {values} {
    set result {}
    dict for {key value} $values {dict set result $key [db_value $value -type [field_type $key]]}
    return $result
}
proc ::web::forum::insert {store table row} {
    if {$table eq "web_forum_topics" && ![dict exists $row last_activity_at]} {dict set row last_activity_at [dict get $row created_at]}
    dict set row tenant [dict get $store -tenant]
    db_execute [dict get $store -connection] [db_values [db_insert $table] [values $row] -expressions]
}
proc ::web::forum::update {store table where row} {
    dict get [db_execute [dict get $store -connection] [db_where \
        [db_values [db_update $table] [values $row] -expressions] [predicate $store $where]]] rowcount
}
proc ::web::forum::one {store table id} {
    lindex [dict get [db_execute [dict get $store -connection] \
        [db_where [db_select $table] [predicate $store [dict create id $id]]]] rows] 0
}
proc ::web::forum::can_moderate {config current} {
    expr {$current ne {} && [::web::user::has_permission [dict get $config -store] [dict get $current id] forum.moderate]}
}
proc ::web::forum::require_moderator {config current} {
    if {![can_moderate $config $current]} {::web::user::fail 403 "Moderator permission is required."}
}
proc ::web::forum::public_filter {store} {predicate $store {status published hidden 0}}
proc ::web::forum::visible {config current row} {
    if {[can_moderate $config $current]} {return 1}
    expr {![dict get $row hidden] && ([dict get $row status] eq "published" || \
        ($current ne {} && [dict get $current id] eq [dict get $row author]))}
}
proc ::web::forum::reply_filter {config current topicId} {
    set store [dict get $config -store]
    set base [predicate $store [dict create topic $topicId]]
    if {[can_moderate $config $current]} {return $base}
    set status [db_eq [db_col status] [db_value published]]
    if {$current ne {}} {set status [db_or $status [db_eq [db_col author] [db_value [dict get $current id]]]]}
    db_and $base [db_eq [db_col hidden] [db_value 0 -type bigint]] $status
}
# Count and page the same visibility-filtered query; use IDs to break time ties.
proc ::web::forum::page_rows {config table filter page {oldest 0} {sort newest}} {
    set store [dict get $config -store]
    set connection [dict get $store -connection]
    set count [db_where [db_select $table -columns [list [db_alias [db_count] total]]] $filter]
    set total [dict get [lindex [dict get [db_execute $connection $count] rows] 0] total]
    set size [dict get $config -config page_size]
    set pages [expr {max(1, ($total + $size - 1) / $size)}]
    if {$page > $pages} {::web::user::fail 404 "Page not found."}
    set order [expr {$oldest ? "db_asc" : "db_desc"}]
    set timeColumn [expr {$table eq "web_forum_topics" && $sort eq "activity" ? "last_activity_at" : "created_at"}]
    set query [db_order_by [db_where [db_select $table] $filter] [$order [db_col $timeColumn]] [$order [db_col id]]]
    set query [db_offset [db_limit $query $size] [expr {($page - 1) * $size}]]
    dict create items [dict get [db_execute $connection $query] rows] page $page pages $pages total $total
}
proc ::web::forum::new_entry {config current form} {
    dict create id [::ksuid::generate_ksuid] author [dict get $current id] body [dict get $form body] \
        created_at [clock seconds] hidden 0 revision 0 \
        status [expr {[dict get $config -config moderation] ? "pending" : "published"}]
}

# Recalculate from visible replies while the caller holds the topic's write lock.
# Hiding a reply removes its activity; restoring it brings that activity back.
proc ::web::forum::refresh_activity {store topicId} {
    set topic [one $store web_forum_topics $topicId]
    if {$topic eq {}} {return}
    set query [db_where [db_select web_forum_replies -columns [list [db_alias [db_max [db_col created_at]] latest]]] \
        [predicate $store [dict create topic $topicId status published hidden 0]]]
    set row [lindex [dict get [db_execute [dict get $store -connection] $query] rows] 0]
    set latest 0
    if {[dict exists $row latest]} {set latest [dict get $row latest]}
    if {![string is wideinteger -strict $latest]} {set latest 0}
    update $store web_forum_topics [dict create id $topicId] \
        [dict create last_activity_at [expr {max([dict get $topic created_at], $latest)}]]
}

# Explicit schema initialization fills activity for already-populated forums.
proc ::web::forum::initialize_activity {connection} {
    set query [db_where [db_select web_forum_topics] [db_eq [db_col last_activity_at] [db_value 0 -type bigint]]]
    db_transaction $connection {
        foreach row [dict get [db_execute $connection $query] rows] {
            refresh_activity [dict create -connection $connection -tenant [dict get $row tenant]] [dict get $row id]
        }
    }
}
