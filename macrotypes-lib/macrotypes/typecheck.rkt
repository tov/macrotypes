#lang racket/base

;; extends "typecheck-core.rkt" with "macrotypes"-only forms

(require (except-in "typecheck-core.rkt")
         (for-syntax racket/stxparam)
         (for-meta 2 racket/base syntax/parse racket/syntax))
(provide (all-from-out "typecheck-core.rkt")
         (all-defined-out)
         (for-syntax (all-defined-out)))

(begin-for-syntax
  (define-syntax-parameter stx (syntax-rules ())))

;; non-Turnstile define-typed-syntax
;; TODO: potentially confusing? get rid of this?
;; - but it will be annoying since the `stx` stx-param is used everywhere
(define-syntax (define-typed-syntax stx)
  (syntax-parse stx
    [(_ name:id stx-parse-clause ...+)
     #'(define-syntax (name syntx)
         (syntax-parameterize ([stx (make-rename-transformer #'syntx)])
           (syntax-parse syntx stx-parse-clause ...)))]))

(begin-for-syntax
  ;; Type assignment macro (ie assign-type) for nicer syntax
  (define-syntax (⊢ stx)
    (syntax-parse stx
      [(_ e tag τ) #'(#%plain-app assign-type #`e #`τ)]
      [(_ e τ) #'(⊢ e : τ)]))

  ;; TODO: remove? only used by macrotypes/examples/infer.rkt (and stlc+cons)
  (define (add-env e env) (set-stx-prop/preserved e 'env (intro-if-stx env)))
  (define (get-env e) (intro-if-stx (syntax-property e 'env)))

  ;; old "infer" fns
  ;; any naming oddities/inconsistentices due to backwards compatibility
  (define (infer es #:ctx [ctx null] #:tvctx [tvctx null]
                    #:tag [tag (current-tag)] ; the "type" to return from es
                    #:stop-list? [stop-list? #t])
       (define/syntax-parse
         (tvs xs (e+ ...))
         (expands/ctxs es #:ctx ctx #:tvctx tvctx #:stop-list? stop-list?))
       (list #'tvs #'xs #'(e+ ...)
             (stx-map (λ (e+ e) (detach/check e+ tag #:orig e)) #'(e+ ...) es)))

  ;; shorter names
  ; ctx = type env for bound vars in term e, etc
  ; can also use for bound tyvars in type e
  (define (infer/ctx+erase ctx e #:tag [tag (current-tag)] #:stop-list? [stop-list? #t])
    (syntax-parse (infer (list e) #:ctx ctx #:tag tag #:stop-list? stop-list?)
      [(_ xs (e+) (τ)) (list #'xs #'e+ #'τ)]))
  (define (infers/ctx+erase ctx es #:tag [tag (current-tag)] #:stop-list? [stop-list? #t])
    (stx-cdr (infer es #:ctx ctx #:tag tag #:stop-list? stop-list?)))
  ; tyctx = kind env for bound type vars in term e
  (define (infer/tyctx+erase ctx e #:tag [tag (current-tag)] #:stop-list? [stop-list? #t])
    (syntax-parse (infer (list e) #:tvctx ctx #:tag tag #:stop-list? stop-list?)
      [(tvs _ (e+) (τ)) (list #'tvs #'e+ #'τ)]))
  (define (infers/tyctx+erase ctx es #:tag [tag (current-tag)] #:stop-list? [stop-list? #t])
    (syntax-parse (infer es #:tvctx ctx #:tag tag #:stop-list? stop-list?)
      [(tvs+ _ es+ τs) (list #'tvs+ #'es+ #'τs)]))
  (define infer/tyctx infer/tyctx+erase)
  (define infer/ctx infer/ctx+erase)

  (define type-pat "[A-Za-z]+")
    
  ;; TODO: remove this? only benefit is single control point for current-promote
  ;;   2018-03-23: not sure this is true; it also enables including exp in err msgs
  ;; NOTE (2018-03-23): current-promote removed
  ;; - infers type of e
  ;; - checks that type of e matches the specified type
  ;; - erases types in e
  ;; - returns e- and its type
  ;;   - does not return type if it's base type
  (define-syntax (⇑ stx)
    (syntax-parse stx #:datum-literals (as)
      [(_ e as tycon)
       #:with τ? (mk-? #'tycon)
       #:with τ-get (format-id #'tycon "~a-get" #'tycon)
       #:with τ-expander (mk-~ #'tycon)
       #'(syntax-parse
             ;; when type error, prefer outer err msg
             (with-handlers ([exn:fail?
                              (λ (ex)
                                (define matched-ty
                                  (regexp-match
                                   (pregexp
                                    (string-append "got\\:\\s(" type-pat ")"))
                                   (exn-message ex)))
                                (unless matched-ty
                                  (raise ex (current-continuation-marks)))
                                (define t-in-msg
                                  (datum->syntax #'here
                                    (string->symbol
                                     (cadr matched-ty))))
                                  (list #'e t-in-msg))])
               (infer+erase #'e))
           #:context #'e
           [(e- τ_e)
            #:fail-unless (τ? #'τ_e)
            (format
             "~a (~a:~a): Expected expression ~s to have ~a type, got: ~a"
             (syntax-source #'e) (syntax-line #'e) (syntax-column #'e)
             (if (has-orig? #'e-)
                 (syntax->datum (get-orig #'e-))
                 (syntax->datum #'e))
             'tycon (type->str #'τ_e))
            (syntax-parse #'τ_e
              [(τ-expander . args) #'(e- args)]
              [_ #'e-])])]))
  (define-syntax (⇑s stx)
    (syntax-parse stx #:datum-literals (as)
      [(_ es as tycon)
       #:with τ? (mk-? #'tycon)
       #:with τ-get (format-id #'tycon "~a-get" #'tycon)
       #:with τ-expander (mk-~ #'tycon)
       #'(syntax-parse (stx-map (lambda (e) (infer+erase e #:stop-list? #f)) #'es) #:context #'es
           [((e- τ_e) (... ...))
            #:when (stx-andmap
                    (λ (e t)
                      (or (τ? t)
                          (type-error #:src e
                                      #:msg
                                      (string-append
                                       (format "Expected expression ~s" (syntax->datum e))
                                       " to have ~a type, got: ~a")
                                      (quote-syntax tycon) t)))
                    #'es
                    #'(τ_e (... ...)))
            #:with res
            (stx-map (λ (e t)
                       (syntax-parse t
                         [(τ-expander . args) #`(#,e args)]
                         [_ e]))
                     #'(e- (... ...))
                     #'(τ_e (... ...)))
            #'res])])))
