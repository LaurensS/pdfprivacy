# The pdfprivacy package

[![Build Status](https://travis-ci.org/LaurensS/pdfprivacy.svg?branch=master)](https://travis-ci.org/LaurensS/pdfprivacy)
[![pipeline status](https://gitlab.com/LaurensS/pdfprivacy/badges/master/pipeline.svg)](https://gitlab.com/LaurensS/pdfprivacy/commits/master)
[![CTAN](https://img.shields.io/ctan/v/pdfprivacy.svg)](https://www.ctan.org/pkg/pdfprivacy)
[![CTAN](https://img.shields.io/ctan/l/pdfprivacy.svg)](https://www.ctan.org/license/lppl1.3c)

Creating pdfs with pdfLaTeX populates several pdf meta-data fields such as date/time of creation/modification, information about the latex installation (e.g., pdfTeX version), and the relative paths of included pdfs. 
The pdfprivacy package provides support for emptying several of these pdf meta-data fields as well as suppressing some pdfTeX meta-data entries in the resulting pdf.

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

## License

This package is available under the conditions of the LaTeX Project Public License, either version 1.3c of this license or (at your option) any later version.

This work consists of the files pdfprivacy.dtx and pdfprivacy.ins and the derived file pdfprivacy.sty.
