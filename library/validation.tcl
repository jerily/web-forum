proc ::web::forum::request_operations {settings} {
    variable root
    set overrides {}
    foreach action {new reply} {
        set path [format {$.%s.requestBody.content['application/x-www-form-urlencoded'].schema.properties.body} $action]
        dict set overrides $path [dict create maxLength [dict get $settings body_max_length]]
    }
    dict set overrides {$.new.requestBody.content['application/x-www-form-urlencoded'].schema.properties.title} \
        [dict create maxLength [dict get $settings title_max_length]]
    ::web::user::read_operations [file join $root assets operations.json] $overrides
}
# Topic IDs are path input, separate from the optional POST form.
proc ::web::forum::validate_topic_id {id} {
    set result [::topenapi::validate_schema [::tjson::typed_to_json [list S $id]] \
        {{"type":"string","pattern":"^[0-9A-Za-z]{27}$"}}]
    if {![dict get $result valid]} {::web::user::fail 404 "Topic not found."}
}
