-- Preserve the approved invariant for all editable package configurations.
do $$declare f text;begin
 f:=pg_get_functiondef('public.admin_save_plan(text,jsonb,integer)'::regprocedure);
 f:=replace(f,'levels:=(p_plan->>''max_generations'')::integer;', 'if (p_plan->>''bv'')::numeric>(p_plan->>''ppv'')::numeric then raise exception ''BV cannot exceed PPV'';end if; levels:=(p_plan->>''max_generations'')::integer;');
 execute f;
end $$;
notify pgrst,'reload schema';
