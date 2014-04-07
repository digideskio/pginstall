;;;
;;; The repository server is also offering a web frontend to manage the
;;; information found in the database, read logs, etc.
;;;
;;;

(in-package #:pginstall.server)

(defvar *dashboard-menu* '(("/"          . "Build Queue")
                           ("/extension" . "Extensions")
                           ("/animal"    . "Animals")
                           ("/build"     . "Builds")
                           ("/archive"   . "Archives"))
  "An alist of HREF and TITLE for the main dashboard menu.")

(defvar *help-menu* '(("/readme"           . "Get Started")
                      ("/help/faq"         . "F.A.Q.")
                      ("/help/api"         . "A.P.I.")
                      ("/help/buildfarm"   . "Buildfarm")
                      ("/help/installer"   . "Installer")
                      ("/help/repository"  . "Repository"))
  "An alist of HREF and TITLE for the help menu.")

(defun serve-loaded-file ()
  "Anything under URL /dist/ gets routed here."
  (handle-loaded-file (hunchentoot:script-name*)))

;;;
;;; Tools to render specific set of pages
;;;
(defun compute-dashboard-menu (current-url-path)
  "List all files found in the *DOCROOT* directory and turns the listing
   into a proper bootstrap menu."
  (when *dburi*
    ;; all the entries in the menu only work properly with a database
    ;; connection (that has been setup), so refrain from displaying them
    ;; when the basic setup has not been done yet.
    (with-html-output-to-string (s)
      (htm
       (:div :class "col-sm-3 col-md-2 sidebar"
             (:ul :class "nav nav-sidebar"
                  (loop :for (href . title) :in *dashboard-menu*
                     :for active := (string= href current-url-path)
                     :do (if active
                             (htm
                              (:li :class "active"
                                   (:a :href (str href) (str title))))
                             (htm
                              (:li
                               (:a :href (str href) (str title))))))))))))

(defun serve-dashboard-page (content)
  "Serve a static page: header then footer."
  (concatenate 'string
               *header*
               (compute-dashboard-menu (hunchentoot:script-name*))
               content
               *footer*))

;;;
;;; Render documentation
;;;
(defun compute-help-menu (current-url-path)
  "List all files found in the *DOCROOT* directory and turns the listing
   into a proper bootstrap menu."
  (with-html-output-to-string (s)
    (htm
     (:div :class "col-sm-3 col-md-2 sidebar"
           (:ul :class "nav nav-sidebar"
                (loop :for (href . title) :in *help-menu*
                   :for active := (string= href current-url-path)
                   :do (if active
                           (htm
                            (:li :class "active"
                                 (:a :href (str href) (str title))))
                           (htm
                            (:li
                             (:a :href (str href) (str title)))))))))))

(defun render-doc-page ()
  "Anything under URL /help/ gets routed here."
  (concatenate 'string
               *header*
               (compute-help-menu (hunchentoot:script-name*))
               (gethash (hunchentoot:script-name*) *fs*)
               *footer*))

(defun readme ()
  "Render the main README.md document, which ain't located under *docroot*."
  (concatenate 'string
               *header*
               (compute-help-menu (hunchentoot:script-name*))
               (markdown-to-html *readme*)
               *footer*))

;;;
;;; Some basic URL formating, for filling-in :href attributes
;;;
(defun extension-href (extension-or-shortname)
  (format nil "/extension/~a"
          (typecase extension-or-shortname
            (extension (short-name extension-or-shortname))
            (string    extension-or-shortname))))

(defun extension-queue-href (extension-or-shortname)
  (format nil "/queue/~a"
          (typecase extension-or-shortname
            (extension (short-name extension-or-shortname))
            (string    extension-or-shortname))))

(defun animal-href (name)
  (format nil "/animal/~a" name))

(defun archive-href (extension-short-name pgversion os version arch)
  (format nil "/api/fetch/~a/~a/~a/~a/~a"
          extension-short-name
          pgversion
          os
          version
          arch))

(defun archive-filename (extension-short-name pgversion os version arch)
  (format nil "~a--~a--~a--~a--~a.tar.gz"
          extension-short-name
          pgversion
          os
          version
          arch))

(defun buildlog-href (log-id)
  (format nil "/build/~a" log-id))

;;;
;;; Main entry points for the web server.
;;;
(defun home ()
  "Display some default home page when the setup hasn't been made, or the
   build queue."
  (let* ((ping (when *dburi*
                 (ignore-errors
                   (with-pgsql-connection (*dburi*)
                     (query "select 1" :single)))))
         ;; maybe the database has been created but no setup has been made
         ;; therein yet.
         (table-list (when ping
                       (with-pgsql-connection (*dburi*)
                         (query "select relname
                                   from      pg_class c
                                        join pg_namespace n
                                          on c.relnamespace = n.oid
                                  where n.nspname = 'public'
                                        and c.relkind = 'r'
                               order by relname"
                                :column)))))
   (if (and ping (equalp *model-table-list* table-list))
       (front-list-build-queue)
       *noconf*)))

(defun config ()
  "Serve the configuration file as a textarea..."
  (let ((ini (read-file-into-string *config-filename*)))
    (serve-dashboard-page
     (with-html-output-to-string (s)
       (htm
        (:div :class "col-sm-9 col-sm-offset-3 col-md-10 col-md-offset-2 main"
              (:h1 :class "page-header" "Repository Server Configuration")
              (:form :role "config"
                     (:div :class "pull-right"
                           :style "margin-bottom: 1em;"
                           (:button :type "submit"
                                    :disabled "disabled"
                                    :class "btn btn-danger"
                                    "Save and Reload Server Configuration"))
                     (:div :class "form-group"
                           (:label :for "config" (str (namestring *config-filename*)))
                           (:textarea :id "config"
                                      :class "form-control"
                                      :rows 15
                                      (str ini))))))))))


;;;
;;; Some listings
;;;
(defun front-list-build-queue ()
  "List all our extensions."
  (let ((queue
         (with-pgsql-connection (*dburi*)
           (query "select * from pginstall.list_build_queue()"))))
   (serve-dashboard-page
    (with-html-output-to-string (s)
      (htm
       (:div :class "col-sm-9 col-sm-offset-3 col-md-10 col-md-offset-2 main"
             (:h1 :class "page-header" "Extensions Build Queue")
             (:div :class "table-responsive"
                   (:table :class "table table-stripped"
                           (:thead
                            (:tr (:th "#")
                                 (:th "Extension")
                                 (:th "Queue State")
                                 (:th "Animal")
                                 (:th "Build date" " " (:em "(or start date)"))
                                 (:th "OS")
                                 (:th "Version")
                                 (:th "Architecture")))
                           (:tbody
                            (loop :for (id shortname state done started animal
                                           os version arch) :in queue
                               :do (htm
                                    (:tr
                                     (:td (str id))
                                     (:td (:a :href (extension-href shortname)
                                              (str shortname)))
                                     (:td (if (string= state "done")
                                              (htm (:span :class "label label-success"
                                                          (str state)))
                                              (htm (:span :class "label label-warning"
                                                          (str state)))))
                                     (:td (if (eq animal :null) (str "")
                                              (htm
                                               (:a :href (animal-href animal)
                                                   (str animal)))))
                                     (:td (if (eq done :null)
                                              (htm
                                               (:em (str (if (eq :null started) ""
                                                             started))))
                                              (str done)))
                                     (:td (str os))
                                     (:td (str version))
                                     (:td (if (eq arch :null) ""
                                              (str arch)))))))))))))))

(defun front-list-extensions ()
  "List all our extensions."
  (serve-dashboard-page
   (with-html-output-to-string (s)
     (htm
      (:div :class "col-sm-9 col-sm-offset-3 col-md-10 col-md-offset-2 main"
            (:h2 "Add an extension")
            (:form :class "form-horizontal" :role "add-extension"
                   :method "post"
                   :action "/add/extension"
                   (:div :class "form-group"
                         (:label :for "fullname"
                                 :class "col-sm-2 control-label"
                                 "Full Name")
                         (:div :class "col-sm-10"
                               (:input :type "text" :class "form-control"
                                       :id "fullname"
                                       :name "fullname"
                                       :placeholder "github.com/user/extension")))

                   (:div :class "form-group"
                         (:label :for "uri" :class "col-sm-2 control-label"
                                 "Git URI")
                         (:div :class "col-sm-10"
                               (:input :type "text" :class "form-control"
                                       :id "uri"
                                       :name "uri"
                                       :placeholder "https://github.com/user/ext.git")))

                   (:div :class "form-group"
                         (:label :for "description" :class "col-sm-2 control-label"
                                 "Description")
                         (:div :class "col-sm-10"
                               (:input :type "text" :class "form-control"
                                       :id "description"
                                       :name "description"
                                       :placeholder "Some Description text.")))
                   (:div :class "form-group"
                         (:div :class "col-sm-offset-2 col-sm-10"
                               (:button :class "btn btn-primary"
                                        :type "submit"
                                        "Add Extension")))))
      (:div :class "col-sm-9 col-sm-offset-3 col-md-10 col-md-offset-2 main"
            (:h1 :class "page-header" "Extensions")
            (:div :class "table-responsive"
                  (:table :class "table table-stripped"
                          (:thead
                           (:tr (:th "#")
                                (:th "Short Name")
                                (:th "Queue a build")
                                (:th "Full Name")
                                (:th "Description")))
                          (:tbody
                           (loop :for extension :in (sort
                                                     (select-star 'extension)
                                                     #'string<
                                                     :key #'short-name)
                              :do (htm
                                   (:tr
                                    (:td (str (ext-id extension)))
                                    (:td (:a :href (extension-href extension)
                                             (str (short-name extension))))
                                    (:td (:a :href (extension-queue-href extension)
                                             :class "btn btn-xs btn-info"
                                             "Queue Build"))
                                    (:td (:a :href (uri extension)
                                             (str (full-name extension))))
                                    (:td (str (desc extension))))))))))))))

(defun front-display-extension (name)
  "Display a detailed view about a given animal (by NAME)."
  (destructuring-bind (extension archive-list)
      (with-pgsql-connection (*dburi*)
        (let ((extension      (query "select id, fullname, shortname, uri, description
                                        from extension
                                       where shortname = $1"
                                     name
                                     (:dao extension :single)))
              (archive-list   (query "select a.name as animal, bl.id,
                                             pgversion,
                                             p.os_name , p.os_version, p.arch
                                        from archive ar
                                             join extension e on ar.extension = e.id
                                             join platform p on ar.platform = p.id
                                             join buildlog bl on ar.log = bl.id
                                             join animal a on bl.animal = a.id
                                       where e.shortname = $1"
                                     name)))
          (list extension archive-list)))
    (serve-dashboard-page
     (with-html-output-to-string (s)
       (htm
        (:div :class "col-sm-9 col-sm-offset-3 col-md-10 col-md-offset-2 main"
              (:h1 :class "page-header"
                   (str (format nil "Extension ~a" name)))
              (:div :class "row"
                    (htm
                     (:div :class "col-xs-6 col-md-5"
                           (:ul :class "list-group"
                            (:li :class "list-group-item list-group-item-info"
                                                 (:h4 :class "list-group-item-heading"
                                                      (str (short-name extension))))
                            (:li :class "list-group-item"
                                 (:dl :class "dl-horizontal"
                                      :style "margin-left: -6em;"
                                      (:dt "#")
                                      (:dd (str (ext-id extension)))
                                      (:dt "Full Name")
                                      (:dd (str (full-name extension)))
                                      (:dt "Git URI")
                                      (:dd (str (uri extension)))
                                      (:dt "Description")
                                      (:dd (str (desc extension)))))))
                     (:div :class "col-xs-6 col-md-7"
                           (:table :class "table table-stripped"
                                   (:thead
                                    (:tr (:th "Animal")
                                         (:th "Build Log")
                                         (:th "Archive")))
                                   (:tbody
                                    (loop :for (animal log
                                                       pgversion os version arch)
                                       :in archive-list

                                       :for filename := (archive-filename
                                                         (short-name extension)
                                                         pgversion os version arch)
                                       :for href := (archive-href
                                                     (short-name extension)
                                                     pgversion os version arch)
                                       :do (htm
                                            (:tr (:td (:a :href (animal-href animal)
                                                          (str animal)))
                                                 (:td (:a :href (buildlog-href log)
                                                          (str log)))
                                                 (:td (:a :href href
                                                          (str filename)))))))))))))))))

(defun front-list-animals ()
  "List all our animals."
  (let ((animal-list
         (with-pgsql-connection (*dburi*)
           (query "select a.name, p.os_name, p.os_version, p.arch,
                          case when substring(r.pict, 1, 7) = 'http://'
                               then pict
                               else '/pict/' || r.pict
                           end as pict,
                          count(p.os_name) over(partition by p.os_name) as same_os,
                          count(p.arch)    over(partition by p.arch) as same_arch
                   from animal a
                        join platform p on a.platform = p.id
                        join registry r on a.name = r.name
               order by a.name"))))
    (serve-dashboard-page
     (with-html-output-to-string (s)
       (htm
        (:div :class "col-sm-9 col-sm-offset-3 col-md-10 col-md-offset-2 main"
              (:h1 :class "page-header" "Build Farm Animals")
              (:div :class "row"
                    (loop :for (name os version arch pict os-nb arch-nb) :in animal-list
                       :do (htm
                            (:div :class "col-xs-6 col-md-3"
                                  (:ul :class "list-group"
                                       (:li :class "list-group-item list-group-item-info"
                                            (:h4 :class "list-group-item-heading"
                                                 (:a :href (animal-href name)
                                                     (str name))))
                                       (:li :class "list-group-item"
                                            (:div :style "width: 150px; height: 150px;"
                                                  (:a :href (animal-href name)
                                                      :class "thumbnail"
                                                     (:img :src (str pict)
                                                           :alt (str name)))))
                                       (:li :class "list-group-item"
                                            (str arch)
                                            (:span :class "badge" (str arch-nb)))
                                       (:li :class "list-group-item"
                                            (str os)
                                            (:span :class "badge" (str os-nb)))
                                       (:li :class "list-group-item"
                                            (str version)))))))))))))

(defun front-display-animal (name)
  "Display a detailed view about a given animal (by NAME)."
  (destructuring-bind (animal pgconfig-list)
      (with-pgsql-connection (*dburi*)
        (let ((animal (query "select a.name, p.os_name, p.os_version, p.arch,
                                     case when substring(r.pict, 1, 7) = 'http://'
                                          then pict
                                          else '/pict/' || r.pict
                                      end as pict
                                from animal a
                                     join platform p on a.platform = p.id
                                     join registry r on a.name = r.name
                               where a.name = $1"
                             name
                             :row))
              (pgconfig-list
               (query-dao 'pgconfig "select pgc.*
                                       from pgconfig pgc
                                            join animal a on a.id = pgc.animal
                                      where a.name = $1"
                          name)))
          (list animal pgconfig-list)))
    (serve-dashboard-page
     (with-html-output-to-string (s)
       (htm
        (:div :class "col-sm-9 col-sm-offset-3 col-md-10 col-md-offset-2 main"
              (:h1 :class "page-header"
                   (str (format nil "Build Farm Animal ~a" name)))
              (:div :class "row"
                    (destructuring-bind (name os version arch pict)
                        animal
                      (htm
                       (:div :class "col-xs-6 col-md-3"
                             (:ul :class "list-group"
                                  (:li :class "list-group-item list-group-item-info"
                                       (:h4 :class "list-group-item-heading"
                                            (str name)))
                                  (:li :class "list-group-item"
                                       (:div :style "width: 150px; height: 150px;"
                                             (:img :src (str pict)
                                                   :alt (str name))))
                                  (:li :class "list-group-item" (str arch))
                                  (:li :class "list-group-item" (str os))
                                  (:li :class "list-group-item" (str version))))
                       (:div :class "col-xs-6 col-md-8"
                             (loop :for pgcfg :in pgconfig-list
                                :do (htm
                                     (:h3 (str (pg-config pgcfg)))
                                     (:table :class "table table-bordered table-striped"
                                             (:colgroup (:col :class "col-xs-1")
                                                        (:col :class "col-xs-7"))
                                             (:thead
                                              (:tr
                                               (:th "Property")
                                               (:th "Value")))
                                             (htm
                                              (:tbody
                                               (:tr
                                                (:th "version")
                                                (:td (str (pg-version pgcfg))))
                                               (:tr
                                                (:th "configure")
                                                (:td (:code
                                                      (str (pg-configure pgcfg)))))
                                               (:tr
                                                (:th "cc")
                                                (:td (:code
                                                      (str (pg-cc pgcfg)))))
                                               (:tr
                                                (:th "cflags")
                                                (:td (:code
                                                      (str (pg-cflags pgcfg))))))))))))))))))))

(defun front-list-builds ()
  "List recent build logs."
  (let ((builds
         (with-pgsql-connection (*dburi*)
           (query "select bl.id,
                          to_char(bl.buildstamp, 'YYYY-MM-DD HH24:MI:SS'),
                          e.fullname, a.name, p.os_name, p.os_version, p.arch,
                          bl.log
                     from buildlog bl
                          join extension e on e.id = bl.extension
                          join animal a    on a.id = bl.animal
                          join platform p  on p.id = a.platform
                 order by bl.buildstamp desc nulls last
                    limit 15"))))
    (serve-dashboard-page
     (with-html-output-to-string (s)
       (htm
        (:div :class "col-sm-9 col-sm-offset-3 col-md-10 col-md-offset-2 main"
              (:h1 :class "page-header" "Build logs")
              (:div :class "table-responsive"
                    (:table :class "table table-stripped"
                            (:thead
                             (:tr (:th "Build Log Information")
                                  (:th "Log")))
                            (:tbody
                             (loop :for (id stamp extension animal
                                            os version arch log) :in builds
                                :do (htm
                                     (:tr
                                      (:td
                                       (:ul :class "list-group"
                                            (:li :class "list-group-item list-group-item-info"
                                                 (:h4 :class "list-group-item-heading"
                                                      (str extension)))
                                            (:li :class "list-group-item"
                                                 (:dl :class "dl-horizontal"
                                                      :style "margin-left: -6em;"
                                                      (:dt "#")
                                                      (:dd (:a :href (buildlog-href id)
                                                               (:strong
                                                                (str id))))
                                                      (:dt "Build date")
                                                      (:dd (str stamp))
                                                      (:dt "Animal")
                                                      (:dd (:a :href (animal-href animal)
                                                               (str animal)))
                                                      (:dt "OS")
                                                      (:dd (str os))
                                                      (:dt "Version")
                                                      (:dd (str version))
                                                      (:dt "Arch")
                                                      (:dd (str arch))))))
                                      (:td (:pre :class "pre-scrollable"
                                                 :style "white-space: pre-wrap;"
                                                 (str log)))))))))))))))

(defun front-display-build (id)
  "Display a detailed view of the given build number."
  (let ((build
         (with-pgsql-connection (*dburi*)
           (query "select bl.id,
                          to_char(bl.buildstamp, 'YYYY-MM-DD HH24:MI:SS'),
                          e.fullname, a.name, p.os_name, p.os_version, p.arch,
                          bl.log
                     from buildlog bl
                          join extension e on e.id = bl.extension
                          join animal a    on a.id = bl.animal
                          join platform p  on p.id = a.platform
                    where bl.id = $1"
                  id
                  :row))))
    (destructuring-bind (id stamp extension animal os version arch log)
        build
      (serve-dashboard-page
       (with-html-output-to-string (s)
         (htm
          (:div :class "col-sm-9 col-sm-offset-3 col-md-10 col-md-offset-2 main"
                (:h1 :class "page-header" "Build log #" (str id))
                (:div :class "table-responsive"
                      (:table :class "table table-stripped"
                              (:thead
                               (:tr (:th "#")
                                    (:th "Build Date")
                                    (:th "Extension")
                                    (:th "Animal")
                                    (:th "OS")
                                    (:th "Version")
                                    (:th "Architecture")))
                              (:tbody
                               (:tr
                                (:td (str id))
                                (:td (str stamp))
                                (:td (str extension))
                                (:td (:a :href (str (animal-href animal))
                                         (str animal)))
                                (:td (str os))
                                (:td (str version))
                                (:td (str arch))))))
                (:pre :style "overflow:auto; word-wrap: normal;"
                      (str log)))))))))

(defun front-list-archives ()
  "List recent build logs."
  (let ((archives
         (with-pgsql-connection (*dburi*)
           (query "select ar.id,
                          bl.id, format('/build/%s', bl.id) as blhref,
                          e.fullname, e.shortname, a.name, pgversion,
                          p.os_name, p.os_version, p.arch
                     from archive ar
                          join buildlog bl on bl.id = ar.log
                          join animal a on bl.animal = a.id
                          join extension e on e.id = ar.extension
                          join platform p  on p.id = ar.platform
                 order by bl.buildstamp desc nulls last
                    limit 15"))))
    (serve-dashboard-page
     (with-html-output-to-string (s)
       (htm
        (:div :class "col-sm-9 col-sm-offset-3 col-md-10 col-md-offset-2 main"
              (:h1 :class "page-header" "Extension Archives")
              (:div :class "table-responsive"
                    (:table :class "table table-stripped"
                            (:thead
                             (:tr (:th "#")
                                  (:th "Build log")
                                  (:th "Extension")
                                  (:th "Built by")
                                  (:th "Archive")))
                            (:tbody
                             (loop :for (archive-id log-id log-href
                                                    extension shortname animal
                                                    pgversion os version arch)
                                :in archives
                                :for fname := (archive-filename shortname pgversion
                                                                os version arch)
                                :for href := (archive-href shortname pgversion
                                                           os version arch)
                                :do (htm
                                     (:tr
                                      (:td (str archive-id))
                                      (:td (:a :href log-href
                                               (:strong (str log-id))))
                                      (:td (:a :href (extension-href shortname)
                                               (str extension)))
                                      (:td (:a :href (animal-href animal)
                                               (str animal)))
                                      (:td (:a :href href
                                               (str fname)))))))))))))))


;;;
;;; Front :POST queries: do the action then redirect to some frontend page.
;;;
(defun front-queue-build (name)
  "Queue an extension's build then hop to the queue listing page."
  (queue-extension-build name)
  (front-list-build-queue))

(defun front-set-dburi ()
  "Setup our *dburi* parameter, then the DB itlsef."
  (let ((dburi (hunchentoot:post-parameter "dburi")))
    (setup dburi)
    ;; if we get here, the setup has been successful
    (set-option-by-name "dburi" dburi)
    (front-list-extensions)))

(defun front-add-extension ()
  "Add an extension to the database"
  (format t "PLOP: ~s~%" (hunchentoot:post-parameters hunchentoot:*request*))
  (let ((full-name     (hunchentoot:post-parameter "fullname"))
        (uri           (hunchentoot:post-parameter "uri"))
        (description   (hunchentoot:post-parameter "description")))
    (with-pgsql-connection (*dburi*)
      (make-dao 'extension :full-name full-name :uri uri :desc description))

    ;; and redirect to the extension's listing
    (front-list-extensions)))
