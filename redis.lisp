;;; CL-REDIS implementation of the wire protocol
;;; (c) Vsevolod Dyomkin, Oleksandr Manzyuk. see LICENSE file for permissions

(in-package #:redis)


(defconstant +crlf-bytes+ #(13 10))

(defun terpri% (out)
  (write-sequence +crlf-bytes+ out))

;; Utils.

(defun format-redis-line (fmt &rest args)
  "Write a CRLF-terminated string formatted according to the given control
string FMT and its arguments ARGS to the stream of the current connection.
If *ECHOP-P* is not NIL, write that string to *ECHO-STREAM*, too."
  (let ((str (apply #'fmt fmt args))
        (out (conn-stream *connection*)))
    (when *echo-p* (format *echo-stream* " > ~A~%" str))
    (write-sequence (flex:string-to-octets str :external-format +utf8+) out)
    (terpri% out)))


;;; Conditions

(define-condition redis-error (error)
  ((error :initform nil
          :initarg :error
          :reader redis-error-error)
   (message :initform nil
            :initarg :message
            :reader redis-error-message))
  (:report (lambda (e stream)
             (format stream
                     "Redis error: ~A~:[~;~2&~:*~A~]"
                     (redis-error-error e)
                     (redis-error-message e))))
  (:documentation "Any Redis-related error."))

(define-condition redis-connection-error (redis-error)
  ()
  (:documentation "Conditions of this type are signaled when errors occur
that break the connection stream.  They offer a :RECONNECT restart."))

(define-condition redis-error-reply (redis-error)
  ()
  (:documentation "Error reply is received from Redis server."))

(define-condition redis-bad-reply (redis-error)
  ()
  (:documentation "Redis protocol error is detected."))


;;; Sending commands to the server

(defgeneric tell (cmd &rest args)
  (:documentation "Send a command to Redis server over a socket connection.
CMD is the command name (a string or a symbol), and ARGS are its arguments
\(keyword arguments are also supported)."))

(defmethod tell :after (cmd &rest args)
  (declare (ignore cmd args))
  (force-output (conn-stream *connection*)))

(defmethod tell (cmd &rest args)
  (let ((all-args (cl:append (ppcre:split "-" (princ-to-string cmd))
                             args)))
    (format-redis-line "*~A" (length all-args))
    (dolist (arg all-args)
      (let ((arg (princ-to-string arg)))
        (format-redis-line "$~A" (flex:octet-length arg :external-format +utf8+))
        (format-redis-line "~A"  arg)))))


;; Pipelining

(defvar *pipelined* nil
  "Indicates, that commands are sent in pipelined mode.")

(defvar *pipeline* nil
  "A list of expected results from the current pipeline.")

(defmacro with-pipelining (&body body)
  "Delay execution of EXPECT's inside BODY to the end, so that all
commands are first sent to the server and then their output is received
and collected into a list.  So commands return :PIPELINED instead of the
expected results."
  `(if *pipelined*
       (progn
         (warn "Already in a pipeline.")
         ,@body)
       (with-reconnect-restart
         (let (*pipeline*)
           (let ((*pipelined* t))
             ,@body)
           (mapcar #'expect (reverse *pipeline*))))))


;;; Receiving replies

(defgeneric expect (type)
  (:documentation "Receive and process the reply of the given type from Redis server."))

(defmethod expect :around (type)
  (if *pipelined*
      (progn (push type *pipeline*)
             :pipelined)
      (call-next-method)))

(eval-always

(defmacro with-redis-in ((line char) &body body)
  `(let* ((,line (read-line (conn-stream *connection*)))
          (,char (char ,line 0)))
     (when *echo-p* (format *echo-stream* "<  ~A~%" ,line))
     ,@body))

(defmacro def-expect-method (type &body body)
  "Define a specialized EXPECT method.  BODY may refer to the ~
variable REPLY, which is bound to the reply received from Redis ~
server with the first character removed."
  (with-unique-names (line char)
    `(defmethod expect ((type (eql ,type)))
       ,(fmt "Receive and process the reply of type ~A." type)
       (with-redis-in (,line ,char)
         (let ((reply (subseq ,line 1)))
           (if (string= ,line "+QUEUED") "QUEUED"
               (case ,char
                 (#\- (error 'redis-error-reply :message reply))
                 ((#\+ #\: #\$ #\*) ,@body)
                 (otherwise
                  (error 'redis-bad-reply
                         :message (fmt "Received ~C as the initial reply byte."
                                       ,char))))))))))
) ; end of eval-always

(defmethod expect ((type (eql :anything)))
  "Receive and process status reply, which is just a string, preceeded with +."
  (case (peek-char nil (conn-stream *connection*))
    (#\+ (expect :status))
    (#\: (expect :integer))
    (#\$ (expect :bulk))
    (#\* (expect :multi))
    (otherwise (expect :status))))  ; will do error-signalling

(defmethod expect ((type (eql :status)))
  "Receive and process status reply, which is just a string, preceeded with +."
  (with-redis-in (line char)
    (case char
      (#\- (error 'redis-error-reply :message (subseq line 1)))
      (#\+ (subseq line 1))
      (otherwise (error 'redis-bad-reply
                        :message (fmt "Received ~C as the initial reply byte."
                                      char))))))

(def-expect-method :inline
  reply)

(def-expect-method :boolean
  (ecase (char reply 0)
    (#\0 nil)
    (#\1 t)))

(def-expect-method :integer
  (values (parse-integer reply)))

(defmacro read-bulk-reply (&key post-processing (encoding +utf8+))
  (with-gensyms (n bytes in str)
    `(let ((,n (parse-integer reply)))
       (unless (< ,n 0)
         (let ((,bytes (make-array ,n :element-type 'flex:octet))
               (,in (conn-stream *connection*)))
           (read-sequence ,bytes ,in)
           (read-byte ,in)               ; #\Return
           (read-byte ,in)               ; #\Linefeed
           ,(if encoding
                `(let ((,str (flex:octets-to-string ,bytes
                                                    :external-format ',encoding)))
                   (when *echo-p* (format *echo-stream* "<  ~A~%" ,str))
                   (unless (string= "nil" ,str)
                     (if ,post-processing
                         (funcall ,post-processing ,str)
                         ,str)))
                bytes))))))

(def-expect-method :bulk
  (read-bulk-reply))

(def-expect-method :multi
  (let ((n (parse-integer reply)))
    (unless (= n -1)
      (loop :repeat n
         :collect (ecase (peek-char nil (conn-stream *connection*))
                    (#\: (expect :integer))
                    (#\$ (expect :bulk))
                    (#\* (expect :multi)))))))

(def-expect-method :queued
  (let ((n (parse-integer reply)))
    (unless (= n -1)
      (loop :repeat n
         :collect (expect :anything)))))

(defmethod expect ((type (eql :pubsub)))
  (let ((in (conn-stream *connection*)))
    (loop :collect (with-redis-in (line char)
                     (list (expect :bulk)
                           (expect :bulk)
                           (expect :inline)))
       :do (let ((next-char (read-char-no-hang in)))
             (if next-char (unread-char next-char in)
                 (loop-finish))))))

(defmethod expect ((type (eql :end)))
  ;; Used for commands QUIT and SHUTDOWN (does nothing)
  )

(defmethod expect ((type (eql :list)))
  ;; Used to make Redis KEYS command return a list of strings (keys)
  ;; rather than a single string
  (cl-ppcre:split " " (expect :bulk)))

(def-expect-method :float
  (read-bulk-reply :post-processing (lambda (x)
                                      (parse-float x :type 'double-float))))

(def-expect-method :bytes
  (read-bulk-reply :encoding nil))


;;; Command definition

(defparameter *cmd-prefix* 'red
  "Prefix for functions names that implement Redis commands.")

(defun maybe-multiplexed-tell-and-expect (cmd reply-type &rest args)
  (print "mmtae")
  (break)
  (if-let (multiplexer (conn-multiplexer *connection*))
    ;; multiplexed blocking io
    (let ((connection *connection*)
          (pipelined *pipelined*)
          (callback *callback*))
      (iolib:set-io-handler multiplexer (conn-fd *connection*)
                            :write (lambda (fd event exception)
                                      (declare (ignorable event exception))
                                      (let ((*connection* connection)
                                            (*pipelined* pipelined))
                                        (apply #'tell cmd args))
                                      (iolib:set-io-handler multiplexer
                                                            fd
                                                            :read
                                                            (lambda (fd event exception)
                                                               (declare (ignorable fd event exception))
                                                               (let ((*connection* connection)
                                                                     (*pipelined* pipelined))
                                                                 (multiple-value-call callback
                                                                   (multiple-value-prog1 (expect :anything)
                                                                     (unless pipelined
                                                                       (clear-input (conn-stream connection)))))))
                                                            :one-shot (if (eql cmd 'subscribe) nil t)))
                            :one-shot t))
    (progn
      (apply #'tell cmd args)
      (prog1 (expect reply-type)
        (unless *pipelined*
          (clear-input (conn-stream *connection*)))))))

(defvar *callback*)

(defmacro with-callback (command callback)
  `(let ((*callback* ,callback))
     ,command))

(defmacro def-cmd (cmd (&rest args) reply-type docstring)
  "Define and export a function with the name <*CMD-REDIX*>-<CMD> for
processing a Redis command CMD.  Here REPLY-TYPE is the expected reply
format."
  (let ((cmd-name (intern (fmt "~:@(~A-~A~)" *cmd-prefix* cmd))))
    `(eval-always
       (defun ,cmd ,args
         ,docstring
         (return-from ,cmd
           (with-reconnect-restart
             ,(cond-it
               ((position '&optional args)
                `(apply 'maybe-multiplexed-tell-and-expect ',cmd ,reply-type ,@(subseq args 0 it)
                        (let ((optional-args (list ,@(nthcdr (1+ it) args))))
                          (subseq optional-args 0 (position nil optional-args)))))
               ((position '&rest args)
                `(apply 'maybe-multiplexed-tell-and-expect ',cmd ,reply-type ,@(subseq args 0 it) ,(nth (1+ it) args)))
               (t `(maybe-multiplexed-tell-and-expect ',cmd ,reply-type ,@args))))))
       (abbr ,cmd-name ,cmd)
       (export ',cmd-name '#:redis)
       (import ',cmd '#:red)
       (export ',cmd '#:red))))

;;; end
