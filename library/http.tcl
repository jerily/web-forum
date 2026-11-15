# Validate bounded query parameters identically for local and Lambda requests.
proc ::web::forum::query {request defaults} {
    if {[dict exists $request queryString] && [dict get $request queryString] ne {}} {
        set fields [::web::user::form [dict create headers {content-type application/x-www-form-urlencoded} \
            body [dict get $request queryString]] 2048]
        dict for {key value} $fields {
            if {![dict exists $defaults $key]} {::web::user::fail 400 "Unknown query parameter."}
            dict set defaults $key $value
        }
    }
    if {![regexp {^[1-9][0-9]{0,6}$} [dict get $defaults page]]} {::web::user::fail 400 "Invalid page number."}
    return $defaults
}
proc ::web::forum::index {config request context params} {
    try {
        set current [::web::user::current_user [dict get $config -user] $request $context]
        set query [query $request {page 1 sort newest}]
        set sort [dict get $query sort]
        if {$sort ni {newest activity}} {::web::user::fail 400 "Invalid topic order."}
        set page [page_rows $config web_forum_topics [public_filter [dict get $config -store]] [dict get $query page] 0 $sort]
        dict set page sort $sort
        render $config index $current {} $page $request $context
    } trap {WEB USER} {message opts} {request_error $message $opts}
}
proc ::web::forum::post_form {config action current request context} {
    if {$current eq {}} {::web::user::fail 401 "Sign in to post."}
    set store [dict get $config -store]
    set form [::web::user::form $request [::web::user::property $store form_max_bytes]]
    if {![dict exists $form csrf] || ![::web::user::csrf [dict get $config -user] verify $request $context [dict get $form csrf]]} {
        ::web::user::fail 403 "Invalid CSRF token."
    }
    ::web::user::validate_form $request $form [dict get $config -operations $action]
    set field [expr {$action eq "moderate" ? "reason" : "body"}]
    if {[string trim [dict get $form $field]] eq {}} {::web::user::fail 400 "Enter a $field."}
    if {$action in {new reply}} {render_body $config [dict get $form body]}
    ::web::user::throttle $store [list forum [dict get $current id]] [dict get $config -config post_limit]
    if {$action in {new reply} && [dict get $config -config posting_captcha]} {
        set auth [dict get $config -user]
        set row [::web::user::session $store [::web::user::cookie_token $auth $request]]
        if {![::web::user::check_form_captcha $auth [captcha_binding $config $action $request] $row $form]} {
            ::web::user::fail 400 "CAPTCHA did not match or expired. Reload the form and try again."
        }
    }
    return $form
}
proc ::web::forum::captcha_binding {config action request} {
    list forum [dict get $config -prefix] $action [dict get $request path]
}
proc ::web::forum::new {config request context params} {
    try {
        set auth [dict get $config -user]
        set current [::web::user::current_user $auth $request $context]
        if {[dict get $request method] eq "POST"} {
            set form [post_form $config new $current $request $context]
            if {[string trim [dict get $form title]] eq {}} {::web::user::fail 400 "Enter a topic title."}
            set entry [new_entry topics $config $current $form]
            dict set entry title [string trim [dict get $form title]]
            dict set entry locked 0
            set store [dict get $config -store]
            db_transaction [dict get $store -connection] {insert $store web_forum_topics $entry}
            return [redirect [dict get $config -prefix]/topic/[dict get $entry id]]
        }
        if {$current eq {}} {return [redirect [dict get $auth -prefix]/login]}
        render $config new $current {} {} $request $context
    } trap {WEB USER} {message opts} {request_error $message $opts}
}
proc ::web::forum::topic {config request context params} {
    try {
        set store [dict get $config -store]
        set id [dict get $params id]
        validate_record_id topics $id
        set current [::web::user::current_user [dict get $config -user] $request $context]
        set topic [one $store web_forum_topics $id]
        if {$topic eq {} || ![visible $config $current $topic]} {::web::user::fail 404 "Topic not found."}
        if {[dict get $request method] eq "POST"} {
            set form [post_form $config reply $current $request $context]
            if {[dict get $topic locked] || [dict get $topic hidden] || [dict get $topic status] ne "published"} {
                ::web::user::fail 403 "This discussion is not open for replies."
            }
            set entry [new_entry replies $config $current $form]
            dict set entry topic $id
            db_transaction [dict get $store -connection] {
                # Serialize posting against moderation; a concurrent lock or hide
                # must not allow a reply to slip into a closed discussion.
                if {[update $store web_forum_topics [dict create id $id revision [dict get $topic revision]] \
                        [dict create revision [expr {[dict get $topic revision] + 1}]]] != 1} {
                    ::web::user::fail 409 "Discussion changed; reload and try again."
                }
                insert $store web_forum_replies $entry
                refresh_activity $store $id
            }
            set page [page_rows $config web_forum_replies [reply_filter $config $current $id] 1 1]
            return [redirect [dict get $config -prefix]/topic/$id?page=[dict get $page pages]#[dict get $entry id]]
        }
        set query [query $request {page 1}]
        set page [page_rows $config web_forum_replies [reply_filter $config $current $id] [dict get $query page] 1]
        render $config topic $current $topic $page $request $context
    } trap {WEB USER} {message opts} {request_error $message $opts}
}
proc ::web::forum::profile {config request context params} {
    try {
        set uid [dict get $params id]
        validate_member_id $uid
        set current [::web::user::current_user [dict get $config -user] $request $context]
        set store [dict get $config -store]
        set query [query $request {page 1}]
        set filter [db_and [public_filter $store] [predicate $store [dict create author $uid]]]
        set page [page_rows $config web_forum_topics $filter [dict get $query page]]
        dict set page profile_id $uid
        render $config profile $current {} $page $request $context
    } trap {WEB USER} {message opts} {request_error $message $opts}
}
proc ::web::forum::queue {config request context params} {
    try {
        set current [::web::user::current_user [dict get $config -user] $request $context]
        require_moderator $config $current
        set query [query $request {page 1 kind topics state pending}]
        set kind [dict get $query kind]
        set state [dict get $query state]
        if {$kind ni {topics replies} || $state ni {pending hidden rejected}} {::web::user::fail 400 "Invalid moderation filter."}
        set where [expr {$state eq "hidden" ? [dict create hidden 1] : [dict create status $state hidden 0]}]
        set page [page_rows $config web_forum_$kind [predicate [dict get $config -store] $where] [dict get $query page] 1]
        dict set page kind $kind
        dict set page state $state
        render $config queue $current {} $page $request $context
    } trap {WEB USER} {message opts} {request_error $message $opts}
}
proc ::web::forum::history {config request context params} {
    try {
        set current [::web::user::current_user [dict get $config -user] $request $context]
        require_moderator $config $current
        set query [query $request {page 1 topic {}}]
        set where {}
        if {[dict get $query topic] ne {}} {
            validate_record_id topics [dict get $query topic]
            dict set where topic_id [dict get $query topic]
        }
        set page [page_rows $config web_forum_moderation [predicate [dict get $config -store] $where] [dict get $query page]]
        dict set page topic_filter [dict get $query topic]
        render $config history $current {} $page $request $context
    } trap {WEB USER} {message opts} {request_error $message $opts}
}
# GET shows a confirmation form. Only a CSRF-protected POST changes state.
proc ::web::forum::moderate {config request context params} {
    try {
        set current [::web::user::current_user [dict get $config -user] $request $context]
        require_moderator $config $current
        set store [dict get $config -store]
        set kind [dict get $params kind]
        set id [dict get $params id]
        set action [dict get $params action]
        if {$kind ni {topics replies} || $action ni {approve reject hide restore lock unlock} ||
                ($kind eq "replies" && $action in {lock unlock})} {::web::user::fail 404 "Action not found."}
        validate_record_id $kind $id
        set table web_forum_$kind
        set row [one $store $table $id]
        if {$row eq {}} {::web::user::fail 404 "Post not found."}
        set changes [moderation_changes $row $action]
        set topicId [expr {$kind eq "topics" ? $id : [dict get $row topic]}]
        if {[dict get $request method] eq "POST"} {
            set form [post_form $config moderate $current $request $context]
            if {[dict get $form revision] != [dict get $row revision]} {::web::user::fail 409 "Post changed; reload and try again."}
            dict set changes revision [expr {[dict get $row revision] + 1}]
            db_transaction [dict get $store -connection] {
                if {$kind eq "replies"} {
                    set parent [one $store web_forum_topics $topicId]
                    if {$parent eq {} || [update $store web_forum_topics [dict create id $topicId revision [dict get $parent revision]] \
                            [dict create revision [expr {[dict get $parent revision] + 1}]]] != 1} {
                        ::web::user::fail 409 "Discussion changed; reload and try again."
                    }
                }
                if {[update $store $table [dict create id $id revision [dict get $row revision]] $changes] != 1} {
                    ::web::user::fail 409 "Post changed; reload and try again."
                }
                if {$kind eq "replies"} {refresh_activity $store $topicId}
                insert $store web_forum_moderation [dict create id [new_id moderation] kind $kind \
                    record_id $id topic_id $topicId moderator [dict get $current id] action $action \
                    reason [string trim [dict get $form reason]] created_at [clock seconds] \
                    before_state [moderation_state $row] after_state [moderation_state [dict merge $row $changes]]]
            }
            return [redirect [dict get $config -prefix]/topic/$topicId]
        }
        set page [dict create items [list $row] action $action kind $kind page 1 pages 1 total 1]
        render $config moderate $current {} $page $request $context
    } trap {WEB USER} {message opts} {request_error $message $opts}
}
proc ::web::forum::moderation_state {row} {
    set state [dict create status [dict get $row status] hidden [dict get $row hidden]]
    if {[dict exists $row locked]} {dict set state locked [dict get $row locked]}
    return $state
}
proc ::web::forum::moderation_changes {row action} {
    switch -- $action {
        approve - reject {
            if {[dict get $row status] ne "pending"} {::web::user::fail 409 "This post is no longer pending."}
            return [dict create status [expr {$action eq "approve" ? "published" : "rejected"}]]
        }
        hide - restore {
            set hidden [expr {$action eq "hide"}]
            if {[dict get $row hidden] == $hidden} {::web::user::fail 409 "Visibility already changed."}
            return [dict create hidden $hidden]
        }
        lock - unlock {
            set locked [expr {$action eq "lock"}]
            if {[dict get $row locked] == $locked} {::web::user::fail 409 "Discussion lock already changed."}
            return [dict create locked $locked]
        }
    }
}
