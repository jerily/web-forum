proc ::web::forum::render_body {config markdown} {
    set callback [dict get $config -config render_markdown]
    if {$callback eq {}} {return [::cmark_gfm::render_gfm_html $markdown]}
    try {{*}$callback $markdown} trap {WEB CONTENT} {message options} {
        ::web::user::fail [lindex [dict get $options -errorcode] 2] $message
    }
}

proc ::web::forum::action_links {config kind row moderator} {
    set result {}
    if {$moderator} {
        set actions {}
        if {[dict get $row status] eq "pending"} {lappend actions approve reject}
        lappend actions [expr {[dict get $row hidden] ? "restore" : "hide"}]
        if {$kind eq "topics"} {lappend actions [expr {[dict get $row locked] ? "unlock" : "lock"}]}
        foreach action $actions {
            lappend result [list M [::web::user::text_fields [dict create label [string totitle $action] \
                url [dict get $config -prefix]/moderate/$kind/[dict get $row id]/$action]]]
        }
    }
    list L $result
}

proc ::web::forum::render {config view current topic page request context} {
    set auth [dict get $config -user]
    set store [dict get $config -store]
    set prefix [dict get $config -prefix]
    set moderator [can_moderate $config $current]
    set page [dict merge {items {} page 1 pages 1 total 0 kind topics state pending action {} profile_id {} topic_filter {} sort newest} $page]
    set fields [dict create title [dict get $config -config title] brand [dict get $config -config title] prefix $prefix \
        view $view sort [dict get $page sort] topic_title {} topic_html {} topic_profile_widget {} topic_profile_url {} \
        topic_created_at_datetime {} topic_created_at_label {} topic_status published topic_history_url {} \
        action_url $prefix/new login_url [dict get $auth -prefix]/login csrf {} captcha_id {} captcha_png {} \
        assets [dict get $config -config assets_url] body_max_length [dict get $config -config body_max_length] \
        title_max_length [dict get $config -config title_max_length] \
        page [dict get $page page] pages [dict get $page pages] total [dict get $page total] \
        previous_url {} next_url {} queue_kind [dict get $page kind] queue_state [dict get $page state] \
        moderation_action [string totitle [dict get $page action]] revision {} profile_name {} profile_username {}]
    set profiles {}
    set topicActions {L {}}
    set open 1
    if {$topic ne {}} {
        set author [dict get $topic author]
        dict set profiles $author [render_widget $config profile [dict create user_id $author] $request $context]
        dict set fields topic_profile_widget [dict get $profiles $author]
        dict set fields topic_profile_url $prefix/member/$author
        set created [timestamp [dict get $topic created_at]]
        dict set fields topic_created_at_datetime [dict get $created datetime]
        dict set fields topic_created_at_label [dict get $created label]
        dict set fields topic_title [dict get $topic title]
        dict set fields title [dict get $topic title]
        dict set fields topic_html [render_body $config [dict get $topic body]]
        dict set fields topic_status [dict get $topic status]
        dict set fields topic_history_url $prefix/moderation/history?topic=[dict get $topic id]
        dict set fields action_url $prefix/topic/[dict get $topic id]
        set topicActions [action_links $config topics $topic $moderator]
        set open [expr {![dict get $topic locked] && ![dict get $topic hidden] && [dict get $topic status] eq "published"}]
    }
    if {$current ne {}} {dict set fields csrf [::web::user::csrf $auth issue $request $context {}]}
    if {$current ne {} && $view in {new topic} && $open && [dict get $config -config posting_captcha]} {
        set action [expr {$view eq "new" ? "new" : "reply"}]
        set fields [dict merge $fields [::web::user::issue_form_captcha $auth \
            [captcha_binding $config $action $request] [::web::user::cookie_token $auth $request] $context]]
    }
    set base [dict get $request path]
    set separator ?
    if {$view eq "index"} {
        append base ?sort=[dict get $page sort]
        set separator &
    } elseif {$view eq "queue"} {
        append base ?kind=[dict get $page kind]&state=[dict get $page state]
        set separator &
    } elseif {$view eq "history" && [dict get $page topic_filter] ne {}} {
        append base ?topic=[dict get $page topic_filter]
        set separator &
    }
    if {[dict get $page page] > 1} {dict set fields previous_url ${base}${separator}page=[expr {[dict get $page page] - 1}]}
    if {[dict get $page page] < [dict get $page pages]} {dict set fields next_url ${base}${separator}page=[expr {[dict get $page page] + 1}]}
    if {$view eq "profile"} {
        set profile [::web::user::public_profile $store [dict get $page profile_id]]
        dict set fields profile_name [dict get $profile display_name]
        dict set fields profile_username [dict get $profile username]
        dict set fields title [dict get $profile display_name]
    }
    set items {}
    foreach row [dict get $page items] {
        set created [timestamp [dict get $row created_at]]
        dict set row created_at_datetime [dict get $created datetime]
        dict set row created_at_label [dict get $created label]
        if {[dict exists $row last_activity_at]} {
            set activity [timestamp [dict get $row last_activity_at]]
            dict set row activity_datetime [dict get $activity datetime]
            dict set row activity_label [dict get $activity label]
        }
        if {$view eq "history"} {
            set author [dict get $row moderator]
            dict set row url $prefix/topic/[dict get $row topic_id]
            dict set row label [string totitle [dict get $row action]]
        } else {
            set author [dict get $row author]
            set kind [expr {[dict exists $row topic] ? "replies" : "topics"}]
            set topicId [expr {$kind eq "replies" ? [dict get $row topic] : [dict get $row id]}]
            dict set row url $prefix/topic/$topicId
            if {$view in {topic queue moderate}} {
                dict set row body_html [render_body $config [dict get $row body]]
            }
            if {![dict exists $row title]} {
                set parent [one $store web_forum_topics $topicId]
                dict set row title [expr {$parent eq {} ? "Discussion" : [dict get $parent title]}]
            }
            if {$view eq "moderate"} {
                dict set fields action_url $prefix/moderate/$kind/[dict get $row id]/[dict get $page action]
                dict set fields revision [dict get $row revision]
            }
        }
        if {![dict exists $profiles $author]} {
            dict set profiles $author [render_widget $config profile [dict create user_id $author] $request $context]
        }
        dict set row profile_widget [dict get $profiles $author]
        dict set row profile_url $prefix/member/$author
        dict set row member [dict get [::web::user::public_profile $store $author] display_name]
        set typedRow [::web::user::text_fields $row]
        if {$view ne "history"} {
            dict set typedRow hidden [list BOOL [dict get $row hidden]]
            dict set typedRow locked [list BOOL [expr {[dict exists $row locked] && [dict get $row locked]}]]
            dict set typedRow actions [action_links $config $kind $row $moderator]
        }
        lappend items [list M $typedRow]
    }
    set typed [dict merge [dict get $config -config properties] [::web::user::text_fields $fields]]
    dict set typed items [list L $items]
    dict set typed topic_actions $topicActions
    dict set typed signed_in [list BOOL [expr {$current ne {}}]]
    dict set typed can_moderate [list BOOL $moderator]
    dict set typed moderation [list BOOL [dict get $config -config moderation]]
    dict set typed topic_hidden [list BOOL [expr {$topic ne {} && [dict get $topic hidden]}]]
    dict set typed topic_locked [list BOOL [expr {$topic ne {} && [dict get $topic locked]}]]
    dict set typed can_reply [list BOOL $open]
    dict set typed editing [list BOOL [expr {$current ne {} && $view in {new topic} && $open}]]
    set templates [dict get $config -templates]
    set body [::jinja2::render [dict get $templates forum.html.jinja] \
        [::tjson::typed_to_json [list M $typed]] -templates $templates -path forum.html.jinja]
    ::web::user::response 200 $body
}
