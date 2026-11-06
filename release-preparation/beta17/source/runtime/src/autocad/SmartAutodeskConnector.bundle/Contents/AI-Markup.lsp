;;; ===================================================================
;;; AI-Markup.lsp (v2) -  Mark up a drawing for Claude in one command
;;; Shipped with Smart Connector: AI Markup and Clear Markup on the Add-ins tab.
;;;
;;;   AI       1. Draw freehand: click = pen down, move mouse to draw,
;;;               click again = pen up. Repeat for more strokes.
;;;               Enter / Space / right-click / Esc when done.
;;;            2. Type what Claude should do, press Enter.
;;;            -> The request, with your sketch as coordinates, is
;;;               copied. Go to Claude and press Ctrl+V.
;;;               No screenshot is taken.
;;;
;;;   AICLEAR  Delete all AI markup and purge the layer.
;;;
;;; Markup goes on layer AI-MARKUP (red, NO PLOT).
;;; ===================================================================

(vl-load-com)

;;; ---------- helpers ------------------------------------------------

(defun ai:layer (name col / ed)
  (if (not (tblsearch "LAYER" name))
    (entmake (list '(0 . "LAYER") '(100 . "AcDbSymbolTableRecord")
                   '(100 . "AcDbLayerTableRecord") (cons 2 name) '(70 . 0)
                   (cons 62 col) '(6 . "Continuous") '(290 . 0)))
    (progn
      (setq ed (entget (tblobjname "LAYER" name)))
      (setq ed (if (assoc 290 ed)
                 (subst '(290 . 0) (assoc 290 ed) ed)
                 (append ed '((290 . 0)))))
      (setq ed (subst (cons 70 (logand (cdr (assoc 70 ed)) (~ 5))) (assoc 70 ed) ed))
      (setq ed (subst (cons 62 (abs (cdr (assoc 62 ed)))) (assoc 62 ed) ed))
      (entmod ed)))
  name)

(defun ai:replace-all (new old str / pos)
  (setq pos 0)
  (while (setq pos (vl-string-search old str pos))
    (setq str (strcat (substr str 1 pos) new (substr str (+ pos 1 (strlen old))))
          pos (+ pos (strlen new))))
  str)

;; Backslash and braces are MText codes; escape them so the label shows the task as typed.
(defun ai:mtext-safe (str)
  (ai:replace-all "\\}" "}" (ai:replace-all "\\{" "{" (ai:replace-all "\\\\" "\\" str))))

(defun ai:pt2s (p) (strcat (rtos (car p) 2 2) "," (rtos (cadr p) 2 2)))

(defun ai:units (/ u)
  (setq u (getvar "INSUNITS"))
  (cond ((= u 0) "unitless - please confirm")
        ((= u 1) "inches") ((= u 2) "feet")
        ((= u 4) "millimetres") ((= u 5) "centimetres") ((= u 6) "metres")
        (T (strcat "INSUNITS=" (itoa u)))))

(defun ai:clip (str / html res)
  (setq res
    (vl-catch-all-apply
      '(lambda ()
         (setq html (vlax-create-object "htmlfile"))
         (vlax-invoke (vlax-get (vlax-get html 'ParentWindow) 'ClipboardData)
                      'setData "Text" str))))
  (if html (vlax-release-object html))
  (not (vl-catch-all-error-p res)))

;;; ---------- simplify a freehand stroke (Douglas-Peucker) ----------

(defun ai:pdist (p a b / dx dy l2 k)
  ;; 2D distance from p to segment a-b
  (setq dx (- (car b) (car a))
        dy (- (cadr b) (cadr a))
        l2 (+ (* dx dx) (* dy dy)))
  (if (< l2 1e-12)
    (distance (list (car p) (cadr p)) (list (car a) (cadr a)))
    (progn
      (setq k (/ (+ (* (- (car p) (car a)) dx)
                    (* (- (cadr p) (cadr a)) dy))
                 l2)
            k (max 0.0 (min 1.0 k)))
      (distance (list (car p) (cadr p))
                (list (+ (car a) (* k dx))
                      (+ (cadr a) (* k dy)))))))

(defun ai:sub (l s e / r i)
  (setq i e)
  (while (>= i s) (setq r (cons (nth i l) r) i (1- i)))
  r)

(defun ai:rdp (pts tol / n a b i imax dmax d)
  (setq n (length pts))
  (if (< n 3)
    pts
    (progn
      (setq a (car pts) b (last pts) dmax 0.0 imax 0 i 1)
      (while (< i (1- n))
        (setq d (ai:pdist (nth i pts) a b))
        (if (> d dmax) (setq dmax d imax i))
        (setq i (1+ i)))
      (if (> dmax tol)
        (append (ai:rdp (ai:sub pts 0 imax) tol)
                (cdr (ai:rdp (ai:sub pts imax (1- n)) tol)))
        (list a b)))))

;;; ---------- true freehand with grread ------------------------------

(defun ai:make-pline (pts lay w)
  ;; pts in WCS, in drawing order; returns handle
  (if (and (> (length pts) 1)
           (entmake
             (append
               (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") (cons 8 lay)
                     '(100 . "AcDbPolyline") (cons 90 (length pts)) '(70 . 0)
                     (cons 43 w))
               (mapcar '(lambda (p) (cons 10 (list (car p) (cadr p)))) pts))))
    (cdr (assoc 5 (entget (entlast))))))

(defun ai:freehand (lay / inc w gr code p pts down strokes)
  ;; returns list of strokes: each (handle . (wcs points ...))
  (setq inc (/ (getvar "VIEWSIZE") 250.0)
        w   (/ (getvar "VIEWSIZE") 600.0))
  (princ "\nClick = pen down / pen up. Move mouse to draw. Enter, right-click or Esc = done.")
  (defun ai:close-stroke (/ wpts h)
    (if (> (length pts) 2)
      (progn
        (setq wpts (reverse (mapcar '(lambda (q) (trans q 1 0)) pts)))
        (if (setq h (ai:make-pline wpts lay w))
          (setq strokes (cons (cons h wpts) strokes)))))
    (setq pts nil down nil))
  (while
    (progn
      (setq gr (grread T 15 0) code (car gr) p (cadr gr))
      (cond
        ((= code 5)                                   ; mouse move
         (if (and down (> (distance p (car pts)) inc))
           (progn (grdraw (car pts) p 1) (setq pts (cons p pts))))
         T)
        ((= code 3)                                   ; click: toggle pen
         (if down
           (progn
             (setq pts (cons p pts))
             (ai:close-stroke)
             (princ "\nPen up. Click to draw again, Enter when done."))
           (setq pts (list p) down T))
         T)
        ((or (equal gr '(2 13)) (equal gr '(2 32))     ; Enter / Space
             (equal gr '(2 27))                        ; Esc
             (= code 25) (= code 11) (= code 12))     ; right-click
         (if down (ai:close-stroke))
         nil)
        (T T))))
  (redraw)
  (reverse strokes))

;;; ---------- AI : the one command -----------------------------------

(defun c:AI (/ *error* lay oldcme dbm strokes tol task p h bmin bmax ins
               txt fn f i s key closed)
  (defun *error* (msg)
    (redraw)
    (if oldcme (setvar "CMDECHO" oldcme))
    (if (and msg (not (wcmatch (strcase msg) "*CANCEL*,*QUIT*,*BREAK*")))
      (princ (strcat "\nAI error: " msg)))
    (princ))
  (setq dbm (getvar "DBMOD")          ; state BEFORE the markup is drawn
        lay (ai:layer "AI-MARKUP" 1)
        oldcme (getvar "CMDECHO")
        tol (/ (getvar "VIEWSIZE") 80.0))
  (setvar "CMDECHO" 0)

  ;; 1. freehand
  (setq strokes (ai:freehand lay))

  ;; no sketch? one click so Claude knows where
  (if (and (not strokes)
           (setq p (getpoint "\nNo sketch. Click where the task applies (or Enter to skip): ")))
    (setq p (trans p 1 0)))

  ;; extents
  (foreach s strokes
    (foreach q (cdr s)
      (setq bmin (if bmin (mapcar 'min bmin q) q)
            bmax (if bmax (mapcar 'max bmax q) q))))
  (if (and (not bmin) p) (setq bmin p bmax p))

  ;; 2. task text
  (setq task (getstring T "\nWhat should Claude do? "))
  (if (= task "")
    (princ "\nNo task typed - markup kept, nothing copied.")
    (progn
      ;; label next to the sketch
      (if bmax
        (progn
          (setq h (/ (getvar "VIEWSIZE") 60.0)
                ins (list (car bmax) (+ (cadr bmax) h) 0.0))
          (entmake (list '(0 . "MTEXT") '(100 . "AcDbEntity") (cons 8 lay)
                         '(100 . "AcDbMText") (cons 10 ins) (cons 40 h)
                         (cons 41 (* h 25.0)) '(71 . 7)
                         (cons 1 (strcat "AI: " (ai:mtext-safe task)))))))

      ;; 3. build request
      (setq txt (strcat
        "AutoCAD task: " task "\n\n"
        "Drawing: " (getvar "DWGPREFIX") (getvar "DWGNAME")
        (if (= dbm 0) "" "  (has unsaved changes)") "\n"
        "Units: " (ai:units) ".  Coordinates are WCS.\n"))
      (if strokes
        (progn
          (setq txt (strcat txt "\nMy sketch, simplified to its key points "
                            "(follow these as the path / outline):\n")
                i 0)
          (foreach s strokes
            (setq i (1+ i)
                  key (ai:rdp (cdr s) tol)
                  closed (and (> (length key) 2)
                              (< (distance (car key) (last key)) (* 3.0 tol))))
            (setq txt (strcat txt "  Stroke " (itoa i)
                              (if closed " (closed shape)" " (open path)")
                              ", handle " (car s) ": "
                              (apply 'strcat
                                (mapcar '(lambda (q) (strcat (ai:pt2s q) "  ")) key))
                              "\n")))
          (setq txt (strcat txt "  Overall extent: " (ai:pt2s bmin)
                            " to " (ai:pt2s bmax) "\n")))
        (if p (setq txt (strcat txt "Location: " (ai:pt2s p) "\n"))))
      (setq txt (strcat txt
        "\nThe sketch is hand-drawn: straighten it and snap to nearby existing "
        "geometry where that is clearly the intent. Layer AI-MARKUP is my note "
        "to you, not design content - leave it for me to clear.\n"
        "Do not take or read screenshots or previews. Check your work from "
        "entity data only (counts, lengths, areas, handles). Keep the final "
        "report short."))

      (setq fn (strcat (getvar "TEMPPREFIX") "AI-Markup-Prompt.txt"))
      (if (setq f (open fn "w")) (progn (write-line txt f) (close f)))

      (if (ai:clip txt)
        (progn
          (alert (strcat "Copied for Claude.\n\nSwitch to Claude and press Ctrl+V.\n\n"
                         "Task: " task))
          (princ "\nCopied. In Claude press Ctrl+V."))
        (progn
          (princ (strcat "\nClipboard blocked - opening " fn))
          (startapp "notepad" fn)))))

  (setvar "CMDECHO" oldcme)
  (princ))

;;; ---------- AICLEAR ------------------------------------------------

(defun c:AICLEAR (/ ss i n oldcme)
  (initget "Yes No")
  (if (= "Yes" (getkword "\nDelete ALL AI markup? [Yes/No] <No>: "))
    (progn
      (setq n 0)
      (if (tblsearch "LAYER" "AI-MARKUP") (ai:layer "AI-MARKUP" 1))
      (if (setq ss (ssget "_X" '((8 . "AI-MARKUP*"))))
        (repeat (setq i (sslength ss))
          (entdel (ssname ss (setq i (1- i)))) (setq n (1+ n))))
      (if (wcmatch (strcase (getvar "CLAYER")) "AI-MARKUP*") (setvar "CLAYER" "0"))
      (setq oldcme (getvar "CMDECHO"))
      (setvar "CMDECHO" 0)
      (command "_.-PURGE" "_LA" "AI-MARKUP*" "_N")
      (setvar "CMDECHO" oldcme)
      (princ (strcat "\nRemoved " (itoa n) " markup objects.")))
    (princ "\nNothing deleted."))
  (princ))

(princ "\nAI-Markup v2 loaded. Type AI to mark up, AICLEAR to remove.")
(princ)
