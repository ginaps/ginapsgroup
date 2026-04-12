
# GinapsGroup

Sitio web estático desarrollado con Hugo para GINaPs: Grupo de Investigación en Nanotecnología, Polímeros y Sustentabilidad de la #UBA - #CONICET, coordinado por el Dr. Guillermo Copello. 


## Descripción

Este proyecto alberga un sitio web académico con contenido organizado en publicaciones, proyectos, autores y páginas institucionales. El sitio se estructura con contenido en Markdown y se genera como sitio estático mediante Hugo.


## AutomatizaciÃ³n de publicaciones

Las publicaciones y su vÃ­nculo con `content/authors` se pueden normalizar con `scripts/sync-publications.ps1`.

```powershell
./scripts/sync-publications.ps1 -ValidateOnly
./scripts/sync-publications.ps1 -WriteChanges
./scripts/sync-publications.ps1 -TargetDir content/publication/nueva-publicacion -BibFile ruta/al/archivo.bib
./scripts/sync-publications.ps1 -TargetDir content/publication/nueva-publicacion -Doi 10.0000/ejemplo
```

El mapa central de equivalencias entre firmas bibliogrÃ¡ficas y slugs internos vive en `data/author_aliases.yaml`. Si aparece una firma nueva, el modo de validaciÃ³n la reporta para incorporarla antes de sincronizar.

## Contacto
- Gabriel Tovar — creador del proyecto desde 2021
- GitHub: https://github.com/gabrieltovarj

