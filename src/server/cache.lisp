;;;
;;; The repository server is also offering a web frontend to manage the
;;; information found in the database, read logs, etc.
;;;
;;; Cache all the on-disk static files (bootstrap, jquery, css, markdown
;;; docs etc) at load time so that we can have an all-included binary file
;;; for real.

(in-package #:pginstall.server)

(defun markdown-to-html (path)
  "Produce some HTML output from the Markdown document found at PATH."
  (with-html-output-to-string (s)
    (htm
     (:div :class "col-sm-9 col-sm-offset-3 col-md-9 col-md-offset-2 main"
           (str
            (multiple-value-bind (md-object html-string)
                (cl-markdown:markdown path :stream nil)
              (declare (ignore md-object))
              html-string))))))

(defun load-static-file (fs pathname url-path)
  "Load given PATHNAME contents at URL-PATH in FS."
  (cond
    ((string= "md" (pathname-type pathname))
     (setf (gethash (uiop:split-name-type url-path) fs)
           (markdown-to-html (read-file-into-string pathname))))
    (t
     (setf (gethash url-path fs)
           (read-file-into-byte-vector pathname)))))

(defun pathname-to-url (pathname url-path)
  "Transform given PATHNAME into an URL at which to serve it within URL-PATH."
  (multiple-value-bind (flag path-list last-component file-namestring-p)
      (uiop:split-unix-namestring-directory-components (namestring pathname))
    (declare (ignore flag file-namestring-p))
    (format nil "~a~{/~a~}/~a" url-path path-list last-component)))

(defun load-static-directory (fs root url-path)
  "Walk PATH and load all files found in there as binary sequence, FS being
   an hash table referencing the full path against the bytes."
  (flet ((collectp  (dir) (declare (ignore dir)) t)
         (recursep  (dir) (declare (ignore dir)) t)
         (collector (dir)
           (loop :for pathname :in (uiop:directory-files dir)
              :unless (or (uiop:directory-pathname-p pathname)
                          (string= "zip "(pathname-type pathname)))
              :do (let ((url (pathname-to-url
                              (uiop:enough-pathname pathname root) url-path)))
                    (load-static-file fs pathname url)))))
    (uiop:collect-sub*directories root #'collectp #'recursep #'collector)))


;;;
;;; Hunchentoot web server integration
;;;
(defun handle-loaded-file (script-name &optional content-type)
  "A function which act like the hunchentoot::handle-static-file function,
   against our *fs* in-memory pseudo file-system."
  (let ((content (gethash script-name *fs*)))
    (unless content
      ;; file does not exist
      (setf (hunchentoot::return-code*) hunchentoot::+http-not-found+)
      (hunchentoot::abort-request-handler))
    (let (bytes-to-send)
      (setf (hunchentoot::content-type*) (or content-type
					     (hunchentoot:mime-type script-name)
					     "application/octet-stream")
	    (hunchentoot:header-out :last-modified) (hunchentoot::rfc-1123-date
						     (get-universal-time))
	    (hunchentoot::header-out :accept-ranges) "bytes")
      ;;
      ;; To simplify stealing code from hunchentoot
      ;;
      (flexi-streams:with-input-from-sequence (file content)
	(setf bytes-to-send (maybe-handle-range-header file (length content))
	      (hunchentoot::content-length*) bytes-to-send)
	(let ((out (hunchentoot::send-headers))
	      (buf (make-array hunchentoot::+buffer-length+
			       :element-type '(unsigned-byte 8))))
	  (loop
	     (when (zerop bytes-to-send)
	       (return))
	     (let* ((chunk-size (min hunchentoot::+buffer-length+ bytes-to-send)))
	       (unless (eql chunk-size (read-sequence buf file :end chunk-size))
		 (error "can't read from input file"))
	       (write-sequence buf out :end chunk-size)
	       (decf bytes-to-send chunk-size)))
	  (finish-output out))))))

(defun create-loaded-file-dispatcher-and-handler
    (uri-prefix base-path &optional content-type)
  "Creates and returns a dispatch function which will dispatch to a
handler function which emits the file relative to BASE-PATH that is
denoted by the URI of the request relative to URI-PREFIX.  URI-PREFIX
must be a string ending with a slash, BASE-PATH must be a pathname
designator for an existing directory.  If CONTENT-TYPE is not NIL,
it'll be the content type used for all files in the folder."
  (flet ((handler ()
           (let ((request-path
		  (hunchentoot::request-pathname hunchentoot::*request* uri-prefix)))
             (when (null request-path)
               (setf (hunchentoot::return-code*) hunchentoot::+http-forbidden+)
               (hunchentoot::abort-request-handler))
             (handle-loaded-file (merge-pathnames request-path base-path)
				 content-type))))
    (hunchentoot::create-prefix-dispatcher uri-prefix #'handler)))


;;;
;;; Rework some hunchentoot internals that expect file streams so that they
;;; work with our in-memory implementation: file-length is signaling.
;;;
(defun maybe-handle-range-header (file length)
  "Helper function for handle-static-file.  Determines whether the
  requests specifies a Range header.  If so, parses the header and
  position the already opened file to the location specified.  Returns
  the number of bytes to transfer from the file.  Invalid specified
  ranges are reported to the client with a HTTP 416 status code."
  (let ((bytes-to-send length))
    (cl-ppcre:register-groups-bind
     (start end)
     ("^bytes=(\\d+)-(\\d*)$" (hunchentoot::header-in* :range) :sharedp t)
     ;; body won't be executed if regular expression does not match
     (setf start (parse-integer start))
     (setf end (if (> (length end) 0) 
		   (parse-integer end) 
		   (1- length)))
     (when (or (< start 0)
	       (>= end length))
       (setf (hunchentoot::return-code*)
	     hunchentoot::+http-requested-range-not-satisfiable+

	     (hunchentoot::header-out :content-range)
	     (format nil "bytes 0-~D/~D" (1- length) length))
       (throw 'handler-done
	 (format nil "invalid request range (requested ~D-~D, accepted 0-~D)"
		 start end (1- length))))
     (file-position file start)
     (setf (hunchentoot::return-code*)
	   hunchentoot::+http-partial-content+

	   bytes-to-send
	   (1+ (- end start))

	   (hunchentoot::header-out :content-range)
	   (format nil "bytes ~D-~D/~D" start end length)))
    bytes-to-send))

