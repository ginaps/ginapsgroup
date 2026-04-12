# GinapsGroup

Sitio web estatico desarrollado con Hugo para GINaPs: Grupo de Investigacion en Nanotecnologia, Polimeros y Sustentabilidad de la UBA y CONICET, coordinado por el Dr. Guillermo Copello.

## Descripcion

Este proyecto alberga un sitio web academico con contenido organizado en publicaciones, proyectos, autores y paginas institucionales. El sitio se estructura con contenido en Markdown y se genera como sitio estatico mediante Hugo.

## Automatizacion de publicaciones

Las publicaciones y su vinculo con `content/authors` se pueden normalizar con `scripts/sync-publications.ps1`.

```powershell
./scripts/sync-publications.ps1 -ValidateOnly
./scripts/sync-publications.ps1 -ValidateOnly -IgnoreUnresolvedAuthors
./scripts/sync-publications.ps1 -WriteChanges
./scripts/sync-publications.ps1 -TargetDir content/publication/nueva-publicacion -BibFile ruta/al/archivo.bib
./scripts/sync-publications.ps1 -TargetDir content/publication/nueva-publicacion -Doi 10.0000/ejemplo
./scripts/sync-publications.ps1 -ImportOrcidSources
./scripts/sync-publications.ps1 -ImportOrcidSources -WriteChanges
./scripts/run-publication-automation.ps1
```

El mapa central de equivalencias entre firmas bibliograficas y slugs internos vive en `data/author_aliases.yaml`. Si aparece una firma nueva, el modo de validacion la reporta para incorporarla antes de sincronizar.

La validacion tambien revisa publicaciones duplicadas por `title` y por `doi`, y elimina autores repetidos dentro de una misma publicacion al sincronizar.

Las fuentes ORCID que alimentan importaciones automaticas viven en `data/publication_sources.yaml`. El modo `-ImportOrcidSources` lista trabajos faltantes comparando por `doi` y `title`; con `-WriteChanges` crea la carpeta de publicacion, genera `index.md` y guarda `cite.bib` cuando el DOI lo permite.

El comando `scripts/run-publication-automation.ps1` ejecuta el flujo completo: importa novedades desde ORCID, resincroniza autores internos en todo `content/publication` y valida que no haya duplicados. Por defecto permite coautores externos sin perfil interno y falla solo si encuentra duplicados o referencias rotas.

El workflow `.github/workflows/publication-sync.yml` corre esa automatizacion cada lunes a las `09:00 UTC` y tambien se puede lanzar manualmente desde `Actions > Publication Sync`. Si aparecen cambios, hace commit y push automatico para disparar un nuevo deploy en Netlify.

## Contacto

- Gabriel Tovar, creador del proyecto desde 2021
- GitHub: https://github.com/gabrieltovarj
