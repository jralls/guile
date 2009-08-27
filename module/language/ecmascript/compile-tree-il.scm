;;; ECMAScript for Guile

;; Copyright (C) 2009 Free Software Foundation, Inc.

;;;; This library is free software; you can redistribute it and/or
;;;; modify it under the terms of the GNU Lesser General Public
;;;; License as published by the Free Software Foundation; either
;;;; version 3 of the License, or (at your option) any later version.
;;;; 
;;;; This library is distributed in the hope that it will be useful,
;;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;;; Lesser General Public License for more details.
;;;; 
;;;; You should have received a copy of the GNU Lesser General Public
;;;; License along with this library; if not, write to the Free Software
;;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

;;; Code:

(define-module (language ecmascript compile-tree-il)
  #:use-module (language tree-il)
  #:use-module (ice-9 receive)
  #:use-module (system base pmatch)
  #:use-module (srfi srfi-1)
  #:export (compile-tree-il))

(define-syntax ->
  (syntax-rules ()
    ((_ (type arg ...))
     `(type ,arg ...))))

(define-syntax @implv
  (syntax-rules ()
    ((_ sym)
     (-> (module-ref '(language ecmascript impl) 'sym #t)))))

(define-syntax @impl
  (syntax-rules ()
    ((_ sym arg ...)
     (-> (apply (@implv sym) arg ...)))))

(define (empty-lexical-environment)
  '())

(define (econs name gensym env)
  (acons name gensym env))

(define (lookup name env)
  (or (assq-ref env name)
      (-> (toplevel name))))

(define (compile-tree-il exp env opts)
  (values
   (parse-tree-il (comp exp (empty-lexical-environment)))
   env
   env))

(define (location x)
  (and (pair? x)
       (let ((props (source-properties x)))
	 (and (not (null? props))
              props))))

;; for emacs:
;; (put 'pmatch/source 'scheme-indent-function 1)

(define-syntax pmatch/source
  (syntax-rules ()
    ((_ x clause ...)
     (let ((x x))
       (let ((res (pmatch x
                    clause ...)))
         (let ((loc (location x)))
           (if loc
               (set-source-properties! res (location x))))
         res)))))

(define (comp x e)
  (let ((l (location x)))
    (define (let1 what proc)
      (let ((sym (gensym))) 
        (-> (let (list sym) (list sym) (list what)
                 (proc sym)))))
    (define (begin1 what proc)
      (let1 what (lambda (v)
                   (-> (begin (proc v)
                              (-> (lexical v v)))))))
    (pmatch/source x
      (null
       ;; FIXME, null doesn't have much relation to EOL...
       (-> (const '())))
      (true
       (-> (const #t)))
      (false
       (-> (const #f)))
      ((number ,num)
       (-> (const num)))
      ((string ,str)
       (-> (const str)))
      (this
       (@impl get-this '()))
      ((+ ,a)
       (-> (apply (-> (primitive '+))
                  (@impl ->number (comp a e))
                  (-> (const 0)))))
      ((- ,a)
       (-> (apply (-> (primitive '-)) (-> (const 0)) (comp a e))))
      ((~ ,a)
       (@impl bitwise-not (comp a e)))
      ((! ,a)
       (@impl logical-not (comp a e)))
      ((+ ,a ,b)
       (-> (apply (-> (primitive '+)) (comp a e) (comp b e))))
      ((- ,a ,b)
       (-> (apply (-> (primitive '-)) (comp a e) (comp b e))))
      ((/ ,a ,b)
       (-> (apply (-> (primitive '/)) (comp a e) (comp b e))))
      ((* ,a ,b)
       (-> (apply (-> (primitive '*)) (comp a e) (comp b e))))
      ((% ,a ,b)
       (@impl mod (comp a e) (comp b e)))
      ((<< ,a ,b)
       (@impl shift (comp a e) (comp b e)))
      ((>> ,a ,b)
       (@impl shift (comp a e) (comp `(- ,b) e)))
      ((< ,a ,b)
       (-> (apply (-> (primitive '<)) (comp a e) (comp b e))))
      ((<= ,a ,b)
       (-> (apply (-> (primitive '<=)) (comp a e) (comp b e))))
      ((> ,a ,b)
       (-> (apply (-> (primitive '>)) (comp a e) (comp b e))))
      ((>= ,a ,b)
       (-> (apply (-> (primitive '>=)) (comp a e) (comp b e))))
      ((in ,a ,b)
       (@impl has-property? (comp a e) (comp b e)))
      ((== ,a ,b)
       (-> (apply (-> (primitive 'equal?)) (comp a e) (comp b e))))
      ((!= ,a ,b)
       (-> (apply (-> (primitive 'not))
                  (-> (apply (-> (primitive 'equal?))
                             (comp a e) (comp b e))))))
      ((=== ,a ,b)
       (-> (apply (-> (primitive 'eqv?)) (comp a e) (comp b e))))
      ((!== ,a ,b)
       (-> (apply (-> (primitive 'not))
                  (-> (apply (-> (primitive 'eqv?))
                             (comp a e) (comp b e))))))
      ((& ,a ,b)
       (@impl band (comp a e) (comp b e)))
      ((^ ,a ,b)
       (@impl bxor (comp a e) (comp b e)))
      ((bor ,a ,b)
       (@impl bior (comp a e) (comp b e)))
      ((and ,a ,b)
       (-> (if (@impl ->boolean (comp a e))
               (comp b e)
               (-> (const #f)))))
      ((or ,a ,b)
       (let1 (comp a e)
             (lambda (v)
               (-> (if (@impl ->boolean (-> (lexical v v)))
                       (-> (lexical v v))
                       (comp b e))))))
      ((if ,test ,then ,else)
       (-> (if (@impl ->boolean (comp test e))
               (comp then e)
               (comp else e))))
      ((if ,test ,then ,else)
       (-> (if (@impl ->boolean (comp test e))
               (comp then e)
               (@implv *undefined*))))
      ((postinc (ref ,foo))
       (begin1 (comp `(ref ,foo) e)
               (lambda (var)
                 (-> (set! (lookup foo e)
                           (-> (apply (-> (primitive '+))
                                      (-> (lexical var var))
                                      (-> (const 1)))))))))
      ((postinc (pref ,obj ,prop))
       (let1 (comp obj e)
             (lambda (objvar)
               (begin1 (@impl pget
                              (-> (lexical objvar objvar))
                              (-> (const prop)))
                       (lambda (tmpvar)
                         (@impl pput
                                (-> (lexical objvar objvar))
                                (-> (const prop))
                                (-> (apply (-> (primitive '+))
                                           (-> (lexical tmpvar tmpvar))
                                           (-> (const 1))))))))))
      ((postinc (aref ,obj ,prop))
       (let1 (comp obj e)
             (lambda (objvar)
               (let1 (comp prop e)
                     (lambda (propvar)
                       (begin1 (@impl pget
                                      (-> (lexical objvar objvar))
                                      (-> (lexical propvar propvar)))
                               (lambda (tmpvar)
                                 (@impl pput
                                        (-> (lexical objvar objvar))
                                        (-> (lexical propvar propvar))
                                        (-> (apply (-> (primitive '+))
                                                   (-> (lexical tmpvar tmpvar))
                                                   (-> (const 1))))))))))))
      ((postdec (ref ,foo))
       (begin1 (comp `(ref ,foo) e)
               (lambda (var)
                 (-> (set (lookup foo e)
                          (-> (apply (-> (primitive '-))
                                     (-> (lexical var var))
                                     (-> (const 1)))))))))
      ((postdec (pref ,obj ,prop))
       (let1 (comp obj e)
             (lambda (objvar)
               (begin1 (@impl pget
                              (-> (lexical objvar objvar))
                              (-> (const prop)))
                       (lambda (tmpvar)
                         (@impl pput
                                (-> (lexical objvar objvar))
                                (-> (const prop))
                                (-> (apply (-> (primitive '-))
                                           (-> (lexical tmpvar tmpvar))
                                           (-> (const 1))))))))))
      ((postdec (aref ,obj ,prop))
       (let1 (comp obj e)
             (lambda (objvar)
               (let1 (comp prop e)
                     (lambda (propvar)
                       (begin1 (@impl pget
                                      (-> (lexical objvar objvar))
                                      (-> (lexical propvar propvar)))
                               (lambda (tmpvar)
                                 (@impl pput
                                        (-> (lexical objvar objvar))
                                        (-> (lexical propvar propvar))
                                        (-> (inline
                                             '- (-> (lexical tmpvar tmpvar))
                                             (-> (const 1))))))))))))
      ((preinc (ref ,foo))
       (let ((v (lookup foo e)))
         (-> (begin
               (-> (set! v
                         (-> (apply (-> (primitive '+))
                                    v
                                    (-> (const 1))))))
               v))))
      ((preinc (pref ,obj ,prop))
       (let1 (comp obj e)
             (lambda (objvar)
               (begin1 (-> (apply (-> (primitive '+))
                                  (@impl pget
                                         (-> (lexical objvar objvar))
                                         (-> (const prop)))
                                  (-> (const 1))))
                       (lambda (tmpvar)
                         (@impl pput (-> (lexical objvar objvar))
                                (-> (const prop))
                                (-> (lexical tmpvar tmpvar))))))))
      ((preinc (aref ,obj ,prop))
       (let1 (comp obj e)
             (lambda (objvar)
               (let1 (comp prop e)
                     (lambda (propvar)
                       (begin1 (-> (apply (-> (primitive '+))
                                          (@impl pget
                                                 (-> (lexical objvar objvar))
                                                 (-> (lexical propvar propvar)))
                                          (-> (const 1))))
                               (lambda (tmpvar)
                                 (@impl pput
                                        (-> (lexical objvar objvar))
                                        (-> (lexical propvar propvar))
                                        (-> (lexical tmpvar tmpvar))))))))))
      ((predec (ref ,foo))
       (let ((v (lookup foo e)))
         (-> (begin
               (-> (set! v
                        (-> (apply (-> (primitive '-))
                                   v
                                   (-> (const 1))))))
               v))))
      ((predec (pref ,obj ,prop))
       (let1 (comp obj e)
             (lambda (objvar)
               (begin1 (-> (apply (-> (primitive '-))
                                  (@impl pget
                                         (-> (lexical objvar objvar))
                                         (-> (const prop)))
                                  (-> (const 1))))
                       (lambda (tmpvar)
                         (@impl pput
                                (-> (lexical objvar objvar))
                                (-> (const prop))
                                (-> (lexical tmpvar tmpvar))))))))
      ((predec (aref ,obj ,prop))
       (let1 (comp obj e)
             (lambda (objvar)
               (let1 (comp prop e)
                     (lambda (propvar)
                       (begin1 (-> (apply (-> (primitive '-))
                                          (@impl pget
                                                 (-> (lexical objvar objvar))
                                                 (-> (lexical propvar propvar)))
                                          (-> (const 1))))
                               (lambda (tmpvar)
                                 (@impl pput
                                        (-> (lexical objvar objvar))
                                        (-> (lexical propvar propvar))
                                        (-> (lexical tmpvar tmpvar))))))))))
      ((ref ,id)
       (lookup id e))
      ((var . ,forms)
       (-> (begin
             (map (lambda (form)
                    (pmatch form
                      ((,x ,y)
                       (-> (define x (comp y e))))
                      ((,x)
                       (-> (define x (@implv *undefined*))))
                      (else (error "bad var form" form))))
                  forms))))
      ((begin . ,forms)
       `(begin ,@(map (lambda (x) (comp x e)) forms)))
      ((lambda ,formals ,body)
       (let ((%args (gensym "%args ")))
         (-> (lambda '%args %args '()
                     (comp-body (econs '%args %args e) body formals '%args)))))
      ((call/this ,obj ,prop . ,args)
       (@impl call/this*
              obj
              (-> (lambda '() '() '()
                          `(apply ,(@impl pget obj prop) ,@args)))))
      ((call (pref ,obj ,prop) ,args)
       (comp `(call/this ,(comp obj e)
                         ,(-> (const prop))
                         ,@(map (lambda (x) (comp x e)) args))
             e))
      ((call (aref ,obj ,prop) ,args)
       (comp `(call/this ,(comp obj e)
                         ,(comp prop e)
                         ,@(map (lambda (x) (comp x e)) args))
             e))
      ((call ,proc ,args)
       `(apply ,(comp proc e)                
               ,@(map (lambda (x) (comp x e)) args)))
      ((return ,expr)
       (-> (apply (-> (primitive 'return))
                  (comp expr e))))
      ((array . ,args)
       `(apply ,(@implv new-array)
               ,@(map (lambda (x) (comp x e)) args)))
      ((object . ,args)
       (@impl new-object
              (map (lambda (x)
                     (pmatch x
                       ((,prop ,val)
                        (-> (apply (-> (primitive 'cons))
                                   (-> (const prop))
                                   (comp val e))))
                       (else
                        (error "bad prop-val pair" x))))
                   args)))
      ((pref ,obj ,prop)
       (@impl pget
              (comp obj e)
              (-> (const prop))))
      ((aref ,obj ,index)
       (@impl pget
              (comp obj e)
              (comp index e)))
      ((= (ref ,name) ,val)
       (let ((v (lookup name e)))
         (-> (begin
               (-> (set! v (comp val e)))
               v))))
      ((= (pref ,obj ,prop) ,val)
       (@impl pput
              (comp obj e)
              (-> (const prop))
              (comp val e)))
      ((= (aref ,obj ,prop) ,val)
       (@impl pput
              (comp obj e)
              (comp prop e)
              (comp val e)))
      ((+= ,what ,val)
       (comp `(= ,what (+ ,what ,val)) e))
      ((-= ,what ,val)
       (comp `(= ,what (- ,what ,val)) e))
      ((/= ,what ,val)
       (comp `(= ,what (/ ,what ,val)) e))
      ((*= ,what ,val)
       (comp `(= ,what (* ,what ,val)) e))
      ((%= ,what ,val)
       (comp `(= ,what (% ,what ,val)) e))
      ((>>= ,what ,val)
       (comp `(= ,what (>> ,what ,val)) e))
      ((<<= ,what ,val)
       (comp `(= ,what (<< ,what ,val)) e))
      ((>>>= ,what ,val)
       (comp `(= ,what (>>> ,what ,val)) e))
      ((&= ,what ,val)
       (comp `(= ,what (& ,what ,val)) e))
      ((bor= ,what ,val)
       (comp `(= ,what (bor ,what ,val)) e))
      ((^= ,what ,val)
       (comp `(= ,what (^ ,what ,val)) e))
      ((new ,what ,args)
       (@impl new
              (map (lambda (x) (comp x e))
                   (cons what args))))
      ((delete (pref ,obj ,prop))
       (@impl pdel
              (comp obj e)
              (-> (const prop))))
      ((delete (aref ,obj ,prop))
       (@impl pdel
              (comp obj e)
              (comp prop e)))
      ((void ,expr)
       (-> (begin
             (comp expr e)
             (@implv *undefined*))))
      ((typeof ,expr)
       (@impl typeof
              (comp expr e)))
      ((do ,statement ,test)
       (let ((%loop (gensym "%loop "))
             (%continue (gensym "%continue ")))
         (let ((e (econs '%loop %loop (econs '%continue %continue e))))
           (-> (letrec '(%loop %continue) (list %loop %continue)
                       (list (-> (lambda '() '() '()
                                         (-> (begin
                                               (comp statement e)
                                               (-> (apply (-> (lexical '%continue %continue)))
                                                   )))))
                             
                             (-> (lambda '() '() '()
                                         (-> (if (@impl ->boolean (comp test e))
                                                 (-> (apply (-> (lexical '%loop %loop))))
                                                 (@implv *undefined*))))))
                       (-> (apply (-> (lexical '%loop %loop)))))))))
      ((while ,test ,statement)
       (let ((%continue (gensym "%continue ")))
         (let ((e (econs '%continue %continue e)))
           (-> (letrec '(%continue) (list %continue)
                       (list (-> (lambda '() '() '()
                                         (-> (if (@impl ->boolean (comp test e))
                                                 (-> (begin (comp statement e)
                                                            (-> (apply (-> (lexical '%continue %continue))))))
                                                 (@implv *undefined*))))))
                       (-> (apply (-> (lexical '%continue %continue)))))))))
      
      ((for ,init ,test ,inc ,statement)
       (let ((%continue (gensym "%continue ")))
         (let ((e (econs '%continue %continue e)))
           (-> (letrec '(%continue) (list %continue)
                       (list (-> (lambda '() '() '()
                                         (-> (if (if test
                                                     (@impl ->boolean (comp test e))
                                                     (comp 'true e))
                                                 (-> (begin (comp statement e)
                                                            (comp (or inc '(begin)) e)
                                                            (-> (apply (-> (lexical '%continue %continue))))))
                                                 (@implv *undefined*))))))
                       (-> (begin (comp (or init '(begin)) e)
                                  (-> (apply (-> (lexical '%continue %continue)))))))))))
      
      ((for-in ,var ,object ,statement)
       (let ((%enum (gensym "%enum "))
             (%continue (gensym "%continue ")))
         (let ((e (econs '%enum %enum (econs '%continue %continue e))))
           (-> (letrec '(%enum %continue) (list %enum %continue)
                       (list (@impl make-enumerator (comp object e))
                             (-> (lambda '() '() '()
                                         (-> (if (@impl ->boolean
                                                        (@impl pget
                                                               (-> (lexical '%enum %enum))
                                                               (-> (const 'length))))
                                                 (-> (begin
                                                       (comp `(= ,var (call/this ,(-> (lexical '%enum %enum))
                                                                                 ,(-> (const 'pop))))
                                                             e)
                                                       (comp statement e)
                                                       (-> (apply (-> (lexical '%continue %continue))))))
                                                 (@implv *undefined*))))))
                       (-> (apply (-> (lexical '%continue %continue)))))))))
      
      ((block ,x)
       (comp x e))
      (else
       (error "compilation not yet implemented:" x)))))

(define (comp-body e body formals %args)
  (define (process)
    (let lp ((in body) (out '()) (rvars (reverse formals)))
      (pmatch in
        (((var (,x) . ,morevars) . ,rest)
         (lp `((var . ,morevars) . ,rest)
             out
             (if (memq x rvars) rvars (cons x rvars))))
        (((var (,x ,y) . ,morevars) . ,rest)
         (lp `((var . ,morevars) . ,rest)
             `((= (ref ,x) ,y) . ,out)
             (if (memq x rvars) rvars (cons x rvars))))
        (((var) . ,rest)
         (lp rest out rvars))
        ((,x . ,rest) (guard (and (pair? x) (eq? (car x) 'lambda)))
         (lp rest
             (cons x out)
             rvars))
        ((,x . ,rest) (guard (pair? x))
         (receive (sub-out rvars)
             (lp x '() rvars)
           (lp rest
               (cons sub-out out)
               rvars)))
        ((,x . ,rest)
         (lp rest
             (cons x out)
             rvars))
        (()
         (values (reverse! out)
                 rvars)))))
  (receive (out rvars)
      (process)
    (let* ((names (reverse rvars))
           (syms (map (lambda (x)
                        (gensym (string-append (symbol->string x) " ")))
                      names))
           (e (fold acons e names syms)))
      (let ((%argv (lookup %args e)))
        (let lp ((names names) (syms syms))
          (if (null? names)
              ;; fixme: here check for too many args
              (comp out e)
              (-> (let (list (car names)) (list (car syms))
                       (list (-> (if (-> (apply (-> (primitive 'null?)) %argv))
                                     (-> (@implv *undefined*))
                                     (-> (let1 (-> (apply (-> (primitive 'car)) %argv))
                                               (lambda (v)
                                                 (-> (set! %argv
                                                     (-> (apply (-> (primitive 'cdr)) %argv))))
                                                 (-> (lexical v v))))))))
                       (lp (cdr names) (cdr syms))))))))))
