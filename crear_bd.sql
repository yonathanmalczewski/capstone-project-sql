/* =============================================================================
   PROYECTO CAPSTONE - Analisis Exploratorio de Datos (EDA) en PostgreSQL
   Archivo : crear_bd.sql  (setup automatico, se ejecuta con psql)
   Autor   : Yonathan Malczewski

   QUE HACE
     Arma el entorno completo de una sola pasada:
       1. Crea la base capstone_project (solo si todavia no existe).
       2. Se conecta a esa base.
       3. Ejecuta estructura.sql: staging, carga de CSV, limpieza, indices
          y validacion.

   COMO SE EJECUTA (desde la carpeta del repositorio)
       psql -U postgres -f crear_bd.sql
   o desde pgAdmin: clic derecho en el servidor > PSQL Tool, y escribir
       \i 'C:/ruta/a/capstone-sql-olist/crear_bd.sql'

   POR QUE UN ARCHIVO APARTE
     CREATE DATABASE no puede ejecutarse en la misma conexion que despues
     crea las tablas: hay que conectarse a la base nueva, y el Query Tool de
     pgAdmin no puede cambiar de base a mitad de un script. psql si puede
     (con \c), por eso este setup usa comandos propios de psql (los que
     empiezan con "\"). No se ejecuta en el Query Tool de pgAdmin.

   REPRODUCIBLE Y RE-EJECUTABLE
     * Si la base ya existe, no la borra ni falla: solo vuelve a cargar los
       datos (estructura.sql recrea todas las tablas en cada corrida).
     * Ante el primer error se detiene (ON_ERROR_STOP) en lugar de seguir
       ejecutando sobre datos incompletos.
   ============================================================================= */

-- Cortar la ejecucion ante el primer error.
\set ON_ERROR_STOP on

\echo '>> [1/3] Creando la base capstone_project (si no existe)...'
-- PostgreSQL no tiene CREATE DATABASE IF NOT EXISTS. Esta consulta arma la
-- sentencia CREATE DATABASE solo cuando la base no existe, y \gexec la ejecuta.
-- Si la base ya existe, la consulta devuelve 0 filas y no se ejecuta nada.
SELECT 'CREATE DATABASE capstone_project'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'capstone_project')\gexec

\echo '>> [2/3] Conectando a capstone_project...'
\c capstone_project

-- Los archivos .sql estan guardados en UTF-8 (tienen acentos). En Windows,
-- psql usa por defecto otra codificacion (WIN1252) y fallaria al leerlos.
\encoding UTF8

\echo '>> [3/3] Ejecutando estructura.sql (carga, limpieza y validacion)...'
-- \ir busca el archivo en la misma carpeta que crear_bd.sql, sin importar
-- desde que carpeta se ejecute psql.
\ir estructura.sql

\echo '>> Listo: capstone_project creada y cargada. Siguiente paso: analisis.sql'
