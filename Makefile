main:
	pdflatex pdfprivacy.dtx
	makeindex -s gglo.ist -o pdfprivacy.gls pdfprivacy.glo
	makeindex -s gind.ist -o pdfprivacy.ind pdfprivacy.idx
	pdflatex pdfprivacy.dtx
	pdflatex pdfprivacy.dtx
sty:
	latex pdfprivacy.ins
