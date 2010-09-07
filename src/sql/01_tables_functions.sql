CREATE OR REPLACE FUNCTION way_get_geom(bigint) RETURNS geometry AS $$
DECLARE
  id alias for $1;
BEGIN
  -- raise notice 'way_get_geom(%)', id;
  return (select MakeLine(geom) from (select geom from way_nodes join nodes on node_id=nodes.id where way_id=id order by sequence_id) as x);
END;
$$ LANGUAGE plpgsql stable;

CREATE OR REPLACE FUNCTION rel_get_geom(bigint, int) RETURNS geometry AS $$
DECLARE
  id alias for $1;
  rec alias for $2;
  geom_nodes geometry;
  geom_ways  geometry;
  --geom_rels  geometry;
BEGIN
  raise notice 'rel_get_geom(%, %)', id, rec;

  --if rec>0 then
  --  return null;
  --end if;

  geom_nodes:=(select ST_Collect(geom) from nodes where nodes.id in (select member_id from relation_members where relation_id=id and member_type='N'));
  geom_ways:=(select ST_Collect(way_get_geom(ways.id)) from ways where ways.id in (select member_id from relation_members where relation_id=id and member_type='W'));
  --geom_rels:=(select ST_Collect(rel_get_geom(relations.id, rec+1)) from relations where relations.id in (select member_id from relation_members where relation_id=id and member_type='R'));

  return ST_Collect(geom_nodes, geom_ways);
END;
$$ LANGUAGE plpgsql stable;

CREATE OR REPLACE FUNCTION node_assemble_tags(bigint) RETURNS hstore AS $$
DECLARE
  id alias for $1;
BEGIN
  -- raise notice 'node_assemble_tags(%)', id;
  return
    (select
	array_to_hstore(to_textarray(k), to_textarray(v))
      from node_tags
      where id=node_id and k!='created_by'
      group by node_id);
END;
$$ LANGUAGE plpgsql stable;

CREATE OR REPLACE FUNCTION way_assemble_tags(bigint) RETURNS hstore AS $$
DECLARE
  id alias for $1;
BEGIN
  -- raise notice 'way_assemble_tags(%)', id;
  return
    (select
	array_to_hstore(to_textarray(k), to_textarray(v))
      from way_tags
      where id=way_id and k!='created_by'
      group by way_id);
END;
$$ LANGUAGE plpgsql stable;

CREATE OR REPLACE FUNCTION rel_assemble_tags(bigint) RETURNS hstore AS $$
DECLARE
  id alias for $1;
BEGIN
  -- raise notice 'rel_assemble_tags(%)', id;
  return
    (select
	array_to_hstore(to_textarray(k), to_textarray(v))
      from relation_tags
      where id=relation_id and k!='created_by'
      group by relation_id);
END;
$$ LANGUAGE plpgsql stable;

CREATE OR REPLACE FUNCTION assemble_point(bigint) RETURNS boolean AS $$
DECLARE
  id alias for $1;
  geom geometry;
  tags hstore;
BEGIN
  -- get tags
  tags:=node_assemble_tags(id);

  -- if no tags, return
  if array_upper(akeys(tags), 1) is null then
    return false;
  end if;

  -- get geometry
  geom:=(select nodes.geom from nodes where nodes.id=id);

  -- ignore poles
  if abs(Y(geom))=90 then
    return false;
  end if;

  raise notice 'assemble_point(%)', id;

  -- okay, insert
  insert into osm_point
    values (
      'node_'||id,
      tags,
      ST_Transform(geom, 900913)
    );

  return true;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION assemble_line(bigint) RETURNS boolean AS $$
DECLARE
  id alias for $1;
  geom geometry;
  tags hstore;
BEGIN
  -- get tags
  tags:=node_assemble_tags(id);

  -- if no tags, return
  if array_upper(akeys(tags), 1) is null then
    return false;
  end if;

  -- get geometry
  geom:=way_get_geom(id);

  raise notice 'assemble_line(%)', id;

  -- okay, insert
  insert into osm_line
    values (
      'way_'||id,
      tags,
      ST_Transform(geom, 900913)
    );

  return true;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION assemble_rel(bigint) RETURNS boolean AS $$
DECLARE
  id alias for $1;
  geom geometry;
  geom_nodes geometry;
  geom_ways  geometry;
  tags hstore;
  outer_members bigint[];
BEGIN
  -- get tags
  tags:=rel_assemble_tags(id);

  -- if no tags, return
  if array_upper(akeys(tags), 1) is null then
    return false;
  end if;

  -- get geometry
  geom:=rel_get_geom(id, 0);

  raise notice 'assemble_rel(%)', id;

  -- okay, insert
  insert into osm_rel
    values (
      'rel_'||id,
      tags,
      ST_Transform(geom, 900913)
    );

  return true;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION assemble_polygon(bigint) RETURNS boolean AS $$
DECLARE
  id alias for $1;
  geom geometry;
  tags hstore;
BEGIN
  -- get geom - count on osm_line for this
  geom:=(select osm_way from osm_line where osm_id='way_'||id);

  -- check geometry
  if geom is null then
    return false;
  end if;

  if (not IsClosed(geom)) or NPoints(geom)<=3 then
    return false;
  end if;

  tags:=(select osm_tags from osm_line where osm_id='way_'||id);
  -- no need to check if tags is null ... it wouldn't be in osm_line

  raise notice 'assemble_polygon(%)', id;

  -- are we member of any multipolygon relation and are we 'outer'?
  if (select count(*) from relation_members join relation_tags on relation_members.relation_id=relation_tags.relation_id and relation_tags.k='type' where member_id='8125153' and member_type='W' and member_role='outer')>0 then
    return false;
  end if;

  -- okay, insert
  insert into osm_polygon
    values (
      'way_'||id,
      null,
      tags,
      geom
    );

  return true;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION assemble_multipolygon(bigint) RETURNS boolean AS $$
DECLARE
  id alias for $1;
  geom geometry;
  tags hstore;
  outer_members bigint[];
BEGIN
  raise notice 'assemble_multipolygon(%)', id;

  -- get list of outer members
  outer_members:=(select to_intarray(member_id) from relation_members where relation_id=id and member_type='W' and member_role='outer' group by relation_id);

  -- generate multipolygon geometry
  geom:=build_multipolygon(
    (select to_array(way_get_geom(member_id)) from relation_members where relation_id=id and member_type='W' and member_role='outer' group by relation_id),
    (select to_array(way_get_geom(member_id)) from relation_members where relation_id=id and member_type='W' and member_role='inner' group by relation_id));

  -- tags
  tags:=rel_assemble_tags(id);
  -- if only one outer polygon, merge its tags
  if(array_upper(outer_members, 1)=1) then
    tags:=tags_merge(tags, way_assemble_tags(outer_members[1]));
  end if;

  -- okay, insert
  insert into osm_polygon
    values (
      'rel_'||id,
      'rel_'||id,
      tags,
      ST_SetSRID(geom, 900913)
    );

  return true;
END;
$$ LANGUAGE plpgsql;
