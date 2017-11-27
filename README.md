# The pdfprivacy package

Creating pdfs with pdfLaTeX populates several pdf meta-data fields such as date/time of creation/modification, information about the latex installation (e.g., pdfTeX version), and the relative paths of included pdfs.
The pdfprivacy package provides support for emptying several of these pdf meta-data fields as well as supressing some pdfTeX meta-data entries in the resulting pdf.

## Installation

To install run the following:

> latex pdfprivacy.ins

This will generate the `pdfprivacy.sty` file.
Put this file in a directory searched by LaTeX (e.g., ~/texmf or texmf-local) or in the folder of your .tex file in which you want to use it.

## Usage

Include `\usepackage{pdfprivacy}` in your .tex file.
For more detailed usage information, check the documentation.

## Documentation

To generate the documentation run:

> pdflatex pdfprivacy.dtx
